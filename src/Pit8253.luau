local Pit = {}
Pit.__index = Pit

function Pit.new(onTick)
	local channels = {}
	for index = 0, 2 do
		channels[index] = { reload = 0x10000, start = 0, access = 3, mode = 0, gate = index ~= 2, next = math.huge }
	end
	return setmetatable({
		channels = channels,
		timer = channels[0],
		refresh = channels[1],
		now = 0,
		onTick = onTick,
	}, Pit)
end

function Pit:clocksUntilIrq()
	return self.timer.next - self.now
end

function Pit:raiseTimerIrq()
	local timer, now = self.timer, self.now
	timer.next = if timer.mode == 0 then math.huge else now + timer.reload - (now - timer.start) % timer.reload
	self.onTick()
end

function Pit:takeRefresh()
	local refresh, now = self.refresh, self.now
	if refresh.mode ~= 2 or now < refresh.next then
		return 0
	end
	local periods = math.floor((now - refresh.next) / refresh.reload) + 1
	refresh.next += periods * refresh.reload
	return periods
end

function Pit:advance(clocks)
	self.now += clocks
	if self.now >= self.timer.next then
		self:raiseTimerIrq()
	end
	return self:takeRefresh()
end

function Pit:gate2(high)
	local channel = self.channels[2]
	if high and not channel.gate then
		channel.start = self.now
	end
	channel.gate = high
end

function Pit:out2(now)
	local channel = self.channels[2]
	if not channel.running or not channel.gate then
		return channel.mode ~= 0
	end
	local elapsed = (now or self.now) - channel.start
	if channel.mode == 0 then
		return elapsed >= channel.reload
	elseif channel.mode == 2 then
		return elapsed % channel.reload ~= channel.reload - 1
	end
	return elapsed % channel.reload < math.ceil(channel.reload / 2)
end

function Pit:counter(channel)
	if not channel.running or not channel.gate then
		return channel.reload % 0x10000
	end
	local elapsed = self.now - channel.start
	if channel.mode == 0 then
		return (channel.reload - elapsed) % 0x10000
	end
	if channel.mode == 3 then
		return (channel.reload - (elapsed * 2) % channel.reload) % 0x10000
	end
	return (channel.reload - elapsed % channel.reload) % 0x10000
end

function Pit:read(port)
	local channel = self.channels[port - 0x40]
	if not channel then
		return 0xFF
	end
	local value = channel.latched or self:counter(channel)
	if channel.access == 3 and not channel.readHigh then
		channel.readHigh = true
		return value % 256
	end
	channel.latched = nil
	channel.readHigh = false
	return channel.access == 1 and value % 256 or math.floor(value / 256)
end

function Pit:write(port, value)
	if port == 0x43 then
		local channel = self.channels[bit32.rshift(value, 6)]
		if channel then
			local access = bit32.extract(value, 4, 2)
			if access == 0 then
				channel.latched = channel.latched or self:counter(channel)
			else
				local mode = bit32.extract(value, 1, 3)
				channel.access, channel.mode = access, mode >= 6 and mode - 4 or mode
				channel.running, channel.readHigh, channel.low, channel.latched = false, false, nil, nil
				channel.next = math.huge
			end
		end
		return
	end

	local channel = self.channels[port - 0x40]
	if channel.access == 3 then
		if channel.low == nil then
			channel.low = value
			return
		end
		value = channel.low + value * 256
		channel.low = nil
	elseif channel.access == 2 then
		value *= 256
	end
	channel.reload = value == 0 and 0x10000 or value
	channel.start, channel.running = self.now, true
	channel.next = self.now + channel.reload
end

return Pit
