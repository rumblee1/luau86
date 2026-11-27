local AtaDisk = if script then require(script.Parent.AtaDisk) else require("./AtaDisk")
local PcFirmware = if script then require(script.Parent.PcFirmware) else require("./PcFirmware")
local Vga = if script then require(script.Parent.Vga) else require("./Vga")

local ADDRESS_SPACE = 0x100000
local ADDRESS_MASK = ADDRESS_SPACE - 1
local FIRMWARE_BASE = 0xFFFC0000
local EXTENDED_SIZE = 16 * 1024 * 1024
local RAM_SIZE = 640 * 1024
local CGA_START = 0xB8000
local CGA_END = CGA_START + 0x4000

local Bus = { CONVENTIONAL_BYTES = RAM_SIZE }
Bus.__index = Bus

function Bus.new(at)
	return setmetatable({
		memory = buffer.create(at and EXTENDED_SIZE or ADDRESS_SPACE),
		at = at,
		a20 = false,
		atRomEnd = 0xD0000,
		romStart = ADDRESS_SPACE,
		videoVersion = 0,
		optionRomEnd = 0xC8000,
		vgaRomEnd = 0xC0000,
	}, Bus)
end

function Bus:ramKiB()
	return RAM_SIZE / 1024, (buffer.len(self.memory) - ADDRESS_SPACE) / 1024
end

function Bus:mountSystemRom(image)
	local size = buffer.len(image)
	assert(size >= 16 and size <= 0x10000, "System ROM must be between 16 bytes and 64 KiB")
	buffer.fill(self.memory, 0xF0000, 0xFF, 0x10000)
	self.romStart = ADDRESS_SPACE - size
	buffer.copy(self.memory, self.romStart, image)
end

function Bus:mountSeaBios(image, vgaRom, hardDisk)
	assert(self.at and buffer.len(image) == 0x40000, "Expected a 256 KiB system ROM")
	self.firmware = image
	self.pc = PcFirmware.new(vgaRom, hardDisk)
	self.vga = Vga.new()
end

function Bus:mountVgaRom(image)
	local size = buffer.len(image)
	assert(self.at and size > 0 and size <= 0x8000, "Invalid VGA option ROM")
	buffer.copy(self.memory, 0xC0000, image)
	self.vgaRomEnd = 0xC0000 + size
	self.vga = Vga.new()
end

function Bus:mountDiskRom(image)
	local size = buffer.len(image)
	assert(size > 0 and size <= 0x8000, "Invalid disk option ROM size")
	buffer.copy(self.memory, 0xC8000, image)
	self.optionRomEnd = 0xC8000 + size
end

function Bus:mountAtRom(image)
	local size = buffer.len(image)
	assert(self.at and size > 0 and size <= 0x8000, "Invalid AT option ROM")
	buffer.copy(self.memory, 0xD0000, image)
	self.atRomEnd = 0xD0000 + size
end

function Bus:physical(address)
	if not self.at then
		return bit32.band(address, ADDRESS_MASK)
	end
	address = bit32.band(address, 0xFFFFFFFF)
	if self.firmware and address >= FIRMWARE_BASE then
		return address
	end
	if address >= 0xFFFF0000 then
		return 0xF0000 + bit32.band(address, 0xFFFF)
	end
	return self.a20 and address or bit32.band(address, 0xFFEFFFFF)
end

function Bus:ramSpan(address, size)
	local first = self:physical(address)
	local last = first + size - 1
	if last < RAM_SIZE or (self.at and first >= ADDRESS_SPACE and last < EXTENDED_SIZE) then
		if self:physical(address + size - 1) == last then
			return first
		end
	end
	return nil
end

function Bus:read8(address)
	if
		(address >= 0 and address < RAM_SIZE)
		or (address >= ADDRESS_SPACE and address < EXTENDED_SIZE and self.a20 and self.at)
	then
		return buffer.readu8(self.memory, address)
	end
	address = self:physical(address)
	if self.firmware then
		if address >= FIRMWARE_BASE then
			return buffer.readu8(self.firmware, address - FIRMWARE_BASE)
		elseif address >= 0xC0000 and address < ADDRESS_SPACE then
			if bit32.band(self.pc:shadow(address), 1) ~= 0 then
				return buffer.readu8(self.memory, address)
			end
			return if address >= 0xE0000 then buffer.readu8(self.firmware, address - 0xC0000) else 0xFF
		end
	end
	if address < RAM_SIZE or (self.at and address >= ADDRESS_SPACE and address < EXTENDED_SIZE) then
		return buffer.readu8(self.memory, address)
	end
	local vga = self.vga
	if vga and vga.active and address >= Vga.MEMORY_BASE and address < Vga.MEMORY_BASE + Vga.MEMORY_SIZE then
		return vga:readMemory(address - Vga.MEMORY_BASE)
	end
	if
		(address >= CGA_START and address < CGA_END)
		or (address >= self.romStart and address < ADDRESS_SPACE)
		or (address >= 0xC0000 and address < self.vgaRomEnd)
		or (address >= 0xC8000 and address < self.optionRomEnd)
		or (address >= 0xD0000 and address < self.atRomEnd)
	then
		return buffer.readu8(self.memory, address)
	end
	return 0xFF
end

function Bus:write8(address, value)
	if
		(address >= 0 and address < RAM_SIZE)
		or (address >= ADDRESS_SPACE and address < EXTENDED_SIZE and self.a20 and self.at)
	then
		buffer.writeu8(self.memory, address, value)
		return
	end
	address = self:physical(address)
	if self.firmware and address >= 0xC0000 and address < ADDRESS_SPACE then
		if bit32.band(self.pc:shadow(address), 2) ~= 0 then
			buffer.writeu8(self.memory, address, value)
		end
		return
	end
	if address < RAM_SIZE or (self.at and address >= ADDRESS_SPACE and address < EXTENDED_SIZE) then
		buffer.writeu8(self.memory, address, value)
		return
	end
	local vga = self.vga
	if vga and vga.active and address >= Vga.MEMORY_BASE and address < Vga.MEMORY_BASE + Vga.MEMORY_SIZE then
		vga:writeMemory(address - Vga.MEMORY_BASE, bit32.band(value, 0xFF))
		return
	end
	if address >= CGA_START and address < CGA_END then
		local byte = bit32.band(value, 0xFF)
		if buffer.readu8(self.memory, address) ~= byte then
			buffer.writeu8(self.memory, address, byte)
			self.videoVersion += 1
		end
	end
end

function Bus:readPhysical32(address)
	-- Page-table entries are aligned and normally reside in RAM.
	if bit32.band(address, 3) == 0 then
		local mapped = self:physical(address)
		if mapped < RAM_SIZE or (self.at and mapped >= ADDRESS_SPACE and mapped < EXTENDED_SIZE) then
			return buffer.readu32(self.memory, mapped)
		end
	end
	return self:read8(address)
		+ self:read8(address + 1) * 256
		+ self:read8(address + 2) * 65536
		+ self:read8(address + 3) * 16777216
end

function Bus:writePhysical32(address, value)
	if bit32.band(address, 3) == 0 then
		local mapped = self:physical(address)
		if mapped < RAM_SIZE or (self.at and mapped >= ADDRESS_SPACE and mapped < EXTENDED_SIZE) then
			buffer.writeu32(self.memory, mapped, value)
			return
		end
		local vga = self.vga
		if
			vga
			and vga.active
			and mapped >= Vga.MEMORY_BASE
			and mapped <= Vga.MEMORY_BASE + Vga.MEMORY_SIZE - 4
			and vga:tryWriteChain4Dword(mapped - Vga.MEMORY_BASE, bit32.band(value, 0xFFFFFFFF))
		then
			return
		end
	end
	for index = 0, 3 do
		self:write8(address + index, bit32.extract(value, index * 8, 8))
	end
end

function Bus:copyRamToVga(address, mapped, source, length)
	local vga = self.vga
	local last = mapped + length - 1
	if
		vga
		and vga.active
		and mapped >= Vga.MEMORY_BASE
		and last < Vga.MEMORY_BASE + Vga.MEMORY_SIZE
		and self:physical(address + length - 1) == last
	then
		return vga:tryCopyChain4(mapped - Vga.MEMORY_BASE, self.memory, source, length)
	end
	return false
end

function Bus:copyPlanarVga(target, source, count, backwards)
	local vga = self.vga
	if not vga or not vga.active then
		return false
	end
	local first, last = Vga.MEMORY_BASE, Vga.MEMORY_BASE + Vga.MEMORY_SIZE - count
	local dest, src = self:physical(target), self:physical(source)
	return dest >= first
		and dest <= last
		and src >= first
		and src <= last
		and self:physical(target + count - 1) == dest + count - 1
		and self:physical(source + count - 1) == src + count - 1
		and vga:tryCopyPlanar(dest - first, src - first, count, backwards)
end

function Bus:transferDisk(disk, diskOffset, segment, offset, length, writeDisk)
	local base = segment * 16
	while length > 0 do
		local size = math.min(length, 0x10000 - offset)
		local address = self:physical(base + offset)
		if address + size <= RAM_SIZE then
			if writeDisk then
				buffer.copy(disk, diskOffset, self.memory, address, size)
			else
				buffer.copy(self.memory, address, disk, diskOffset, size)
			end
		else
			for index = 0, size - 1 do
				if writeDisk then
					buffer.writeu8(disk, diskOffset + index, self:read8(address + index))
				else
					self:write8(address + index, buffer.readu8(disk, diskOffset + index))
				end
			end
		end
		diskOffset += size
		length -= size
		offset = 0
	end
end

function Bus:readPort(port)
	if self.pc and port >= 0x511 then
		local value = self.pc:read(port)
		if value ~= nil then
			return value
		end
	end
	if self.vga and port >= 0x3C0 and port <= 0x3DA then
		local value = self.vga:readPort(port)
		if value ~= nil then
			return value
		end
	end
	return self.io and self.io:read(port) or 0xFF
end

function Bus:writePort(port, value)
	if self.pc and port >= 0xCF8 and self.pc:write(port, value) then
		return
	end
	if self.vga and port >= 0x3C0 and port <= 0x3DA and self.vga:writePort(port, value) then
		return
	end
	if self.io then
		self.io:write(port, value)
	end
end

function Bus:readIo(port, size)
	if self.pc and port == PcFirmware.PCI_CONFIG_ADDRESS and size == 4 then
		return self.pc.pciAddress
	end
	if self.pc and port == AtaDisk.DATA_PORT and self.io and self.io.hardDisk then
		local disk = self.io:selectedIdeDisk()
		return if disk then disk:readData(size) else 0
	end
	local value = 0
	for index = 0, size - 1 do
		value += self:readPort(bit32.band(port + index, 0xFFFF)) * 256 ^ index
	end
	return value
end

function Bus:readIdeBlock(port, target, count, size)
	if not self.pc or port ~= AtaDisk.DATA_PORT or not self.io or not self.io.hardDisk then
		return 0
	end
	local disk = self.io:selectedIdeDisk()
	return if disk then disk:readBlock(self.memory, target, count, size) else 0
end

function Bus:writeIo(port, value, size)
	if self.pc then
		-- The PCI address register is a dword. Splitting it into bytes would
		-- write to the overlapping PIIX reset control port at CF9h.
		if port == PcFirmware.PCI_CONFIG_ADDRESS and size > 1 then
			if size == 4 then
				self.pc.pciAddress = value
			end
			return
		elseif port == PcFirmware.FW_CFG_SELECTOR and size == 2 then
			self.pc:selectFile(value)
			return
		elseif port == AtaDisk.DATA_PORT and self.io and self.io.hardDisk then
			local disk = self.io:selectedIdeDisk()
			if disk then
				disk:writeData(value, size)
			end
			return
		end
	end
	for index = 0, size - 1 do
		self:writePort(bit32.band(port + index, 0xFFFF), bit32.extract(value, index * 8, 8))
	end
end

return Bus
