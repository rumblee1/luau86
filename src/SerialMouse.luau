local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

local QUEUE_LIMIT, MOVEMENT_LIMIT = 32, 1024
local BYTE_CLOCKS = 8949 -- 1200 baud, one start bit, seven data bits and one stop bit.
local INTERACTIVE_BYTE_CLOCKS = math.round(BYTE_CLOCKS / 4)
local SerialMouse = { BASE = 0x3F8 }
SerialMouse.__index = SerialMouse

function SerialMouse.new(requestInterrupt)
	return setmetatable({
		requestInterrupt = requestInterrupt,
		pending = {},
		bytes = {},
		buttons = 0,
		deliverAt = math.huge,
		reportByteClocks = BYTE_CLOCKS,
		divisorLow = 0,
		divisorHigh = 0,
		interruptEnable = 0,
		lineControl = 0,
		modemControl = 0,
		scratch = 0,
	}, SerialMouse)
end

function SerialMouse:useInteractiveTiming()
	-- A slow guest magnifies the serial delay in wall time. The UART
	-- still delivers one byte per notification and waits for each read.
	self.reportByteClocks = INTERACTIVE_BYTE_CLOCKS
end

function SerialMouse:interrupt()
	if self.received ~= nil and band(self.interruptEnable, 1) ~= 0 and band(self.modemControl, 8) ~= 0 then
		self.requestInterrupt()
	end
end

function SerialMouse:advance(now)
	local bytes = self.bytes
	local queued = #bytes > 0 or #self.pending > 0
	if self.received ~= nil or not queued then
		self.receiveBlocked = queued and self.received ~= nil
		self.deliverAt = math.huge
		return
	end
	if #bytes == 0 then
		local packet = self.pending[1]
		local x, y = math.clamp(packet.dx, -128, 127), math.clamp(packet.dy, -128, 127)
		packet.dx -= x
		packet.dy -= y
		if packet.dx == 0 and packet.dy == 0 then
			table.remove(self.pending, 1)
		end
		local dx, dy = band(x, 255), band(y, 255)
		self.packetMovedAt = if dx ~= 0 or dy ~= 0 then packet.movedAt else nil
		bytes[1] = bor(0x40, packet.buttons, rshift(band(dy, 0xC0), 4), rshift(dx, 6))
		bytes[2], bytes[3] = band(dx, 63), band(dy, 63)
	end
	self.received = table.remove(bytes, 1)
	if #bytes == 0 then
		self.receivedMotionAt, self.packetMovedAt = self.packetMovedAt, nil
	end
	self.deliverAt = now + self.reportByteClocks
	self:interrupt()
end

function SerialMouse:move(dx, dy, buttons, now, movedAt)
	if band(self.modemControl, 0x13) ~= 3 then
		return
	end
	dx, dy = math.round(dx), math.round(dy)
	buttons = band(buttons, 0x30)
	if dx == 0 and dy == 0 and self.buttons == buttons then
		return
	end
	self.buttons = buttons

	-- Coalesce motion until transmission starts. Keep separate reports for
	-- button transitions, even when the cursor has not moved.
	local pending = self.pending
	local last = pending[#pending]
	if last and last.buttons == buttons then
		last.dx = math.clamp(last.dx + dx, -MOVEMENT_LIMIT, MOVEMENT_LIMIT)
		last.dy = math.clamp(last.dy + dy, -MOVEMENT_LIMIT, MOVEMENT_LIMIT)
		last.movedAt = last.movedAt or movedAt
	else
		local nextIndex = math.min(#pending + 1, QUEUE_LIMIT)
		pending[nextIndex] = {
			dx = math.clamp(dx, -MOVEMENT_LIMIT, MOVEMENT_LIMIT),
			dy = math.clamp(dy, -MOVEMENT_LIMIT, MOVEMENT_LIMIT),
			buttons = buttons,
			movedAt = movedAt,
		}
	end
	if self.received == nil and self.deliverAt == math.huge then
		self.deliverAt = now + self.reportByteClocks
	end
end

function SerialMouse:read(port, now)
	local register = port - SerialMouse.BASE
	local divisor = band(self.lineControl, 0x80) ~= 0
	if register == 0 then
		if divisor then
			return self.divisorLow
		end
		local byte = self.received
		self.received = nil
		if self.receivedMotionAt then
			self.lastMotionReadAt, self.receivedMotionAt = self.receivedMotionAt, nil
			self.lastMotionDeliveredAt = os.clock()
			self.motionReports = (self.motionReports or 0) + 1
		end
		if (#self.bytes > 0 or #self.pending > 0) and self.deliverAt == math.huge then
			self.deliverAt = now + (self.receiveBlocked and 1 or self.reportByteClocks)
		end
		self.receiveBlocked = false
		return byte or 0
	elseif register == 1 then
		return if divisor then self.divisorHigh else self.interruptEnable
	elseif register == 2 then
		return if self.received ~= nil and band(self.interruptEnable, 1) ~= 0 then 4 else 1
	elseif register == 3 then
		return self.lineControl
	elseif register == 4 then
		return self.modemControl
	elseif register == 5 then
		return if self.received ~= nil then 0x61 else 0x60
	elseif register == 6 then
		local control = self.modemControl
		if band(control, 0x10) ~= 0 then
			return bor(lshift(band(control, 12), 4), lshift(band(control, 2), 3), lshift(band(control, 1), 5))
		end
		return if band(control, 3) == 3 then 0x30 else 0
	end
	return self.scratch
end

function SerialMouse:write(port, value, now)
	local register = port - SerialMouse.BASE
	local divisor = band(self.lineControl, 0x80) ~= 0
	if register == 0 then
		if divisor then
			self.divisorLow = value
		elseif band(self.modemControl, 0x10) ~= 0 then
			self.received = value
			self:interrupt()
		end
	elseif register == 1 then
		if divisor then
			self.divisorHigh = value
		else
			self.interruptEnable = band(value, 15)
			self:interrupt()
		end
	elseif register == 3 then
		self.lineControl = value
	elseif register == 4 then
		local wasPowered = band(self.modemControl, 0x13) == 3
		local powered = band(value, 0x13) == 3
		self.modemControl = band(value, 31)
		if wasPowered ~= powered then
			table.clear(self.pending)
			table.clear(self.bytes)
			self.buttons = 0
			self.received, self.receiveBlocked = nil, false
			self.packetMovedAt, self.receivedMotionAt, self.lastMotionReadAt = nil, nil, nil
			self.lastMotionDeliveredAt = nil
			self.deliverAt = math.huge
			if powered then
				self.bytes[1] = 0x4D -- Microsoft serial mouse identification byte.
				self.deliverAt = now + 3 * BYTE_CLOCKS
			end
		end
		self:interrupt()
	elseif register == 7 then
		self.scratch = value
	end
end

return SerialMouse
