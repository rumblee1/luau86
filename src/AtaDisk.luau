local band = bit32.band

local FIRST_PORT = 0x1F0
local SECTOR_SIZE, HEADS, SECTORS = 512, 16, 32
local READY, DATA, FAILED = 0x50, 0x58, 0x51

local AtaDisk = { DATA_PORT = FIRST_PORT, DEVICE_PORT = FIRST_PORT + 6, CONTROL_PORT = 0x3F6 }
AtaDisk.__index = AtaDisk

local function identifyDisk(cylinders)
	local identify = buffer.create(SECTOR_SIZE)
	local count = cylinders * HEADS * SECTORS
	buffer.writeu16(identify, 0, 0x0040)
	buffer.writeu16(identify, 1 * 2, cylinders)
	buffer.writeu16(identify, 3 * 2, HEADS)
	buffer.writeu16(identify, 6 * 2, SECTORS)
	for index, byte in { string.byte(string.format("%-40s", "Luau86 ATA disk"), 1, 40) } do
		buffer.writeu8(identify, 54 + bit32.bxor(index - 1, 1), byte)
	end
	buffer.writeu16(identify, 49 * 2, 0x0200) -- LBA
	buffer.writeu16(identify, 53 * 2, 1)
	buffer.writeu16(identify, 54 * 2, cylinders)
	buffer.writeu16(identify, 55 * 2, HEADS)
	buffer.writeu16(identify, 56 * 2, SECTORS)
	buffer.writeu32(identify, 57 * 2, count)
	buffer.writeu32(identify, 60 * 2, count)
	buffer.writeu16(identify, 80 * 2, 0x0010) -- ATA-4
	buffer.writeu16(identify, 83 * 2, 0x4000)
	return identify
end

function AtaDisk.new(source, requestInterrupt)
	local size = buffer.len(source)
	local cylinders = size / (HEADS * SECTORS * SECTOR_SIZE)
	assert(cylinders >= 1 and cylinders <= 127 and cylinders % 1 == 0, "Expected 1–127 whole disk cylinders")
	local image = buffer.create(size)
	buffer.copy(image, 0, source)
	local disk = setmetatable({
		image = image,
		identify = identifyDisk(cylinders),
		registers = buffer.create(8),
		requestInterrupt = requestInterrupt,
		control = 0,
	}, AtaDisk)
	disk:reset()
	return disk
end

function AtaDisk:reset()
	buffer.fill(self.registers, 0, 0)
	buffer.writeu8(self.registers, 2, 1)
	buffer.writeu8(self.registers, 3, 1)
	self.status, self.error = READY, 1
	self.transfer, self.writing = nil, false
end

function AtaDisk:signal()
	if band(self.control, 2) == 0 then
		self.requestInterrupt()
	end
end

function AtaDisk:command(command)
	self.transfer, self.writing = nil, false
	self.status, self.error = READY, 0
	local registers = self.registers
	if command == 0xEC then -- Identify device
		self.transfer, self.cursor, self.last = self.identify, 0, SECTOR_SIZE
		self.status = DATA
	elseif command == 0x20 or command == 0x30 then
		local device = buffer.readu8(registers, 6)
		local sector = buffer.readu8(registers, 3)
		local cylinder = buffer.readu16(registers, 4)
		local head = band(device, 15)
		local lba = if band(device, 0x40) ~= 0
			then sector + 256 * cylinder + 0x1000000 * head
			else (cylinder * HEADS + head) * SECTORS + sector - 1
		local count = buffer.readu8(registers, 2)
		if count == 0 then
			count = 256
		end
		local first, last = lba * SECTOR_SIZE, (lba + count) * SECTOR_SIZE
		if
			(band(device, 0x40) == 0 and (sector < 1 or sector > SECTORS))
			or first < 0
			or last > buffer.len(self.image)
		then
			self.error, self.status = 4, FAILED
		else
			self.transfer, self.cursor, self.last = self.image, first, last
			self.writing, self.status = command == 0x30, DATA
		end
	elseif command ~= 0xE7 and command ~= 0x91 and command ~= 0xEF then -- Flush, initialize parameters, set features
		self.status, self.error = FAILED, 4
	end
	if not self.writing then
		self:signal()
	end
end

function AtaDisk:advanceData(size)
	self.cursor += size
	if self.cursor == self.last then
		self.transfer = nil
		self.status = READY
		if self.writing then
			self:signal()
		end
	elseif self.cursor % SECTOR_SIZE == 0 then
		self:signal()
	end
end

function AtaDisk:readData(size)
	local transfer, cursor = self.transfer, self.cursor
	if not transfer or self.writing or cursor + size > self.last then
		return 0
	end
	local value = if size == 4
		then buffer.readu32(transfer, cursor)
		elseif size == 2 then buffer.readu16(transfer, cursor)
		else buffer.readu8(transfer, cursor)
	self:advanceData(size)
	return value
end

function AtaDisk:writeData(value, size)
	local transfer, cursor = self.transfer, self.cursor
	if not transfer or not self.writing or cursor + size > self.last then
		return
	end
	if size == 4 then
		buffer.writeu32(transfer, cursor, value)
	elseif size == 2 then
		buffer.writeu16(transfer, cursor, value)
	else
		buffer.writeu8(transfer, cursor, value)
	end
	self:advanceData(size)
end

function AtaDisk.handlesPort(port)
	return (port >= FIRST_PORT and port <= FIRST_PORT + 7) or port == AtaDisk.CONTROL_PORT
end

function AtaDisk:read(port)
	if port == AtaDisk.CONTROL_PORT or port == FIRST_PORT + 7 then
		return self.status
	elseif port == FIRST_PORT + 1 then
		return self.error
	elseif port == FIRST_PORT then
		return self:readData(1)
	end
	return buffer.readu8(self.registers, port - FIRST_PORT)
end

function AtaDisk:write(port, value)
	if port == AtaDisk.CONTROL_PORT then
		local previous = self.control
		self.control = value
		if band(value, 4) ~= 0 then
			self.status = 0x80
			self.transfer = nil
		elseif band(previous, 4) ~= 0 then
			self:reset()
		end
	elseif port == FIRST_PORT + 7 then
		self:command(value)
	elseif port == FIRST_PORT then
		self:writeData(value, 1)
	else
		buffer.writeu8(self.registers, port - FIRST_PORT, value)
	end
end

return AtaDisk
