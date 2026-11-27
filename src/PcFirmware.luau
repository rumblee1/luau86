local band, extract = bit32.band, bit32.extract

local RESET_CONTROL_PORT = 0xCF9
local EQUIPMENT_FLAGS = 0x410

local PcFirmware = { FW_CFG_SELECTOR = 0x510, PCI_CONFIG_ADDRESS = 0xCF8 }
PcFirmware.__index = PcFirmware

local function configuration(vendor, device, class)
	local registers = buffer.create(256)
	buffer.writeu16(registers, 0, vendor)
	buffer.writeu16(registers, 2, device)
	buffer.writeu16(registers, 0x0A, class)
	return registers
end

function PcFirmware.new(vgaRom, hardDisk)
	local host = configuration(0x8086, 0x1237, 0x0600)
	buffer.writeu8(host, 8, 2)
	local devices = { [0] = host }
	if hardDisk then
		local isa = configuration(0x8086, 0x7000, 0x0601)
		buffer.writeu8(isa, 0x0E, 0x80)
		devices[8] = isa
		devices[9] = configuration(0x8086, 0x7010, 0x0101)
	end

	-- fw_cfg integers in the file directory use network byte order.
	local directory = buffer.create(68)
	buffer.writeu8(directory, 3, 1)
	local size = buffer.len(vgaRom)
	for i = 0, 3 do
		buffer.writeu8(directory, 4 + i, extract(size, (3 - i) * 8, 8))
	end
	buffer.writeu8(directory, 9, 0x20)
	buffer.writestring(directory, 12, "vgaroms/vgabios.bin")
	return setmetatable({
		devices = devices,
		host = host,
		pciAddress = 0,
		resetControl = 0,
		resetRequested = false,
		awaitingDiskBoot = true,
		fwSelector = 0,
		fwOffset = 0,
		files = {
			[0] = buffer.fromstring("QEMU"),
			[1] = buffer.fromstring("\1\0\0\0"),
			[5] = buffer.fromstring("\1\0"),
			[0x19] = directory,
			[0x20] = vgaRom,
		},
	}, PcFirmware)
end

function PcFirmware:diskBoot(cpu, memory)
	if cpu:protected() then
		return
	end
	-- Stock SeaBIOS assumes the QEMU machine has a math coprocessor.
	-- Correct its equipment word at disk boot so the guest can choose
	-- its own software floating-point support.
	local equipment = buffer.readu8(memory, EQUIPMENT_FLAGS)
	buffer.writeu8(memory, EQUIPMENT_FLAGS, band(equipment, 0xFD))
	self.awaitingDiskBoot = false
end

function PcFirmware:shadow(address)
	if address >= 0xF0000 then
		return extract(buffer.readu8(self.host, 0x59), 4, 2)
	end
	local page = math.floor((address - 0xC0000) / 0x4000)
	return extract(buffer.readu8(self.host, 0x5A + math.floor(page / 2)), page % 2 * 4, 2)
end

function PcFirmware:configTarget(port)
	local address = self.pciAddress
	if extract(address, 31) == 1 and extract(address, 16, 8) == 0 then
		return self.devices[extract(address, 8, 8)], band(address, 0xFC) + port - 0xCFC
	end
	return nil
end

function PcFirmware:read(port)
	if port == 0x511 then
		local file = self.files[self.fwSelector]
		local offset = self.fwOffset
		if file and offset < buffer.len(file) then
			self.fwOffset += 1
			return buffer.readu8(file, offset)
		end
		return 0
	elseif port == RESET_CONTROL_PORT then
		return self.resetControl
	elseif port >= 0xCFC and port <= 0xCFF then
		local registers, offset = self:configTarget(port)
		return if registers then buffer.readu8(registers, offset) else 0xFF
	end
	return nil
end

function PcFirmware:write(port, value)
	if port == RESET_CONTROL_PORT then
		if band(value, 4) ~= 0 then
			self.resetRequested = true
		else
			self.resetControl = band(value, 2)
		end
	elseif port >= 0xCFC and port <= 0xCFF then
		local registers, offset = self:configTarget(port)
		if
			registers and (offset == 4 or offset == 5 or (registers == self.host and offset >= 0x59 and offset <= 0x5F))
		then
			buffer.writeu8(registers, offset, value)
		end
	else
		return false
	end
	return true
end

function PcFirmware:selectFile(selector)
	self.fwSelector = selector
	self.fwOffset = 0
end

return PcFirmware
