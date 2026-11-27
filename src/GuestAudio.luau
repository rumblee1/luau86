local GuestAudio = { SAMPLE_RATE = 24000 }
GuestAudio.__index = GuestAudio

local MAX_SAMPLES = GuestAudio.SAMPLE_RATE / 5

function GuestAudio.new(pit, clockRate)
	return setmetatable({
		pit = pit,
		clocksPerSample = clockRate / GuestAudio.SAMPLE_RATE,
		samples = buffer.create(MAX_SAMPLES * 4),
		count = 0,
		nextSample = pit.now,
		speaker = false,
		dac = 0,
		lastSpeaker = 0,
		filteredSpeaker = 0,
	}, GuestAudio)
end

function GuestAudio:sync(now)
	local count, nextSample, interval = self.count, self.nextSample, self.clocksPerSample
	local endCount = count + math.max(0, math.ceil((now - nextSample) / interval))
	if endCount == count then
		return
	end
	local last = math.min(endCount, MAX_SAMPLES)
	local pit, samples, dac = self.pit, self.samples, self.dac
	local speaker, previous, filtered = self.speaker, self.lastSpeaker, self.filteredSpeaker
	if not speaker and dac == 0 and math.abs(filtered) < 0.00001 and previous == 0 then
		buffer.fill(samples, count * 4, 0, (last - count) * 4)
		self.nextSample = nextSample + (endCount - count) * interval
		self.count = last
		return
	end
	if not speaker and previous == 0 and filtered == 0 then
		-- DMA holds a constant level between writes when the speaker is idle.
		local sample = math.clamp(dac, -1, 1)
		for offset = count * 4, last * 4 - 4, 4 do
			buffer.writef32(samples, offset, sample)
			nextSample += interval
		end
	else
		for index = count, last - 1 do
			local signal = if speaker then (if pit:out2(nextSample) then 0.16 else -0.16) else 0
			-- A PC speaker cannot maintain a DC offset when its input is held high.
			filtered = signal - previous + 0.995 * filtered
			previous = signal
			buffer.writef32(samples, index * 4, math.clamp(dac + filtered, -1, 1))
			nextSample += interval
		end
		self.lastSpeaker, self.filteredSpeaker = previous, filtered
	end
	self.nextSample = nextSample + (endCount - last) * interval
	self.count = last
end

function GuestAudio:setDac(value, now)
	if self.dac ~= value then
		self:sync(now)
		self.dac = value
	end
end

function GuestAudio:take()
	self:sync(self.pit.now)
	local count = self.count
	self.count = 0
	return self.samples, count
end

return GuestAudio
