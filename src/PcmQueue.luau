-- Keep sample order across Roblox frames. When the guest runs slowly, overlap
-- neighboring pieces of the waveform instead of lowering the playback pitch.
-- A slow CPU slice can supply less than a third of real-time audio.
-- Allow the overlap-add resampler to consume samples at that pace.
local MIN_TEMPO, MAX_TEMPO = 0.20, 1.25

local PcmQueue = {}
PcmQueue.__index = PcmQueue

function PcmQueue.new(sourceRate, outputRate)
	local capacity = math.ceil(sourceRate * 0.320)
	local hop = math.ceil(sourceRate * 0.020)
	local overlap = math.ceil(sourceRate * 0.008)
	return setmetatable({
		samples = buffer.create(capacity * 4),
		grain = buffer.create(hop * 4),
		tail = buffer.create(overlap * 4),
		capacity = capacity,
		hop = hop,
		overlap = overlap,
		search = math.ceil(sourceRate * 0.005),
		threshold = math.ceil(sourceRate * 0.085),
		refillStep = math.ceil(sourceRate * 0.020),
		maxThreshold = math.ceil(sourceRate * 0.160),
		speed = sourceRate / outputRate,
		fadeFrames = math.max(1, math.ceil(outputRate * 0.003)),
		sourceRate = sourceRate,
		rateInput = 0,
		rateSeconds = 0,
		tempo = 1,
		start = 0,
		count = 0,
		position = 0,
		grainPosition = hop,
		fade = 0,
		hasTail = false,
		ready = false,
		underruns = 0,
		dropped = 0,
	}, PcmQueue)
end

function PcmQueue:push(source, count, elapsed)
	if elapsed > 0 then
		-- Measure the guest against wall time. Writer silence and changes in
		-- output buffer size change how many frames we render in each call.
		self.rateInput += count
		self.rateSeconds += elapsed
		if self.rateSeconds >= 0.120 then
			local measured = math.clamp(self.rateInput / (self.rateSeconds * self.sourceRate), MIN_TEMPO, MAX_TEMPO)
			self.tempo += (measured - self.tempo) * 0.55
			self.rateInput, self.rateSeconds = 0, 0
		end
	end
	local overflow = math.max(0, self.count + count - self.capacity)
	local skip = 0
	if overflow > 0 then
		local discard = math.min(self.count, overflow)
		self.start = (self.start + discard) % self.capacity
		self.count -= discard
		self.position, self.fade, self.hasTail = 0, 0, false
		skip = overflow - discard
		count -= skip
		self.dropped += overflow
	end

	if count == 0 then
		return
	end
	local start = (self.start + self.count) % self.capacity
	local first = math.min(count, self.capacity - start)
	buffer.copy(self.samples, start * 4, source, skip * 4, first * 4)
	if first < count then
		buffer.copy(self.samples, 0, source, (skip + first) * 4, (count - first) * 4)
	end
	self.count += count
end

local function matchScore(queue, candidate)
	local samples, tail = queue.samples, queue.tail
	local start, capacity = queue.start + candidate, queue.capacity
	local dot, energy = 0, 0
	for index = 0, queue.overlap - 1, 4 do
		local a = buffer.readf32(tail, index * 4)
		local b = buffer.readf32(samples, ((start + index) % capacity) * 4)
		dot += a * b
		energy += b * b
	end
	return dot / math.sqrt(energy + 1e-9)
end

local function alignedStart(queue, expected, first, last)
	local best = math.clamp(expected, first, last)
	if not queue.hasTail or not queue.tailAudible or (queue.start + best) % queue.capacity == queue.tailStart then
		return best
	end
	local score = matchScore(queue, best)
	-- Search coarsely, then refine the best region to single-sample precision.
	for candidate = first, last, 8 do
		local value = matchScore(queue, candidate)
		if value > score then
			best, score = candidate, value
		end
	end
	for candidate = math.max(first, best - 7), math.min(last, best + 7) do
		local value = matchScore(queue, candidate)
		if value > score then
			best, score = candidate, value
		end
	end
	return best
end

local function copySamples(queue, output, start, count)
	local first = math.min(count, queue.capacity - start)
	buffer.copy(output, 0, queue.samples, start * 4, first * 4)
	if first < count then
		buffer.copy(output, first * 4, queue.samples, 0, (count - first) * 4)
	end
end

function PcmQueue:nextGrain()
	local hop, overlap = self.hop, self.overlap
	local expected = math.floor(self.position + 0.5)
	local first = math.max(0, expected - self.search)
	local last = math.min(self.count - hop - overlap, expected + self.search)
	if last < first then
		return false
	end
	local actual = alignedStart(self, expected, first, last)
	local grain, tail, capacity = self.grain, self.tail, self.capacity
	local start = (self.start + actual) % capacity
	copySamples(self, grain, start, hop)
	if self.hasTail and start ~= self.tailStart then
		for index = 0, overlap - 1 do
			local offset = index * 4
			local old = buffer.readf32(tail, offset)
			local sample = buffer.readf32(grain, offset)
			buffer.writef32(grain, offset, old + (sample - old) * (index / overlap))
		end
	end
	self.tailStart = (start + hop) % capacity
	copySamples(self, tail, self.tailStart, overlap)
	local audible = false
	for offset = 0, overlap * 4 - 4, 4 do
		if math.abs(buffer.readf32(tail, offset)) > 1e-5 then
			audible = true
			break
		end
	end
	self.hasTail, self.tailAudible = true, audible
	-- The nominal read position controls tempo. A waveform match may move a
	-- grain slightly, but its offset must not accumulate across the clip.
	local fullness = self.count - self.position
	local correction = (fullness - self.threshold) / (4 * self.threshold)
	local pace = self.tempo
	if fullness < self.threshold * 0.75 and self.rateSeconds >= 0.025 then
		-- Slow down before the regular estimate catches up to a sudden stall.
		pace = math.min(pace, self.rateInput / (self.rateSeconds * self.sourceRate))
	end
	local tempo = math.clamp(pace + correction, MIN_TEMPO, MAX_TEMPO)
	self.position += hop * tempo
	local discard = math.max(0, math.floor(self.position) - self.search)
	self.start = (self.start + discard) % capacity
	self.position -= discard
	self.count -= discard
	return true
end

function PcmQueue:render(output, frames, volume)
	if not self.ready then
		if self.count < self.threshold then
			buffer.fill(output, 0, 0, frames * 4)
			return
		end
		self.ready = true
	end

	local position, fade, hop = self.grainPosition, self.fade, self.hop
	local fadeStep, speed = 1 / self.fadeFrames, self.speed
	local index, sample = 0, self.lastSample or 0
	while index < frames do
		if position >= hop then
			if not self:nextGrain() then
				break
			end
			position -= hop
		end
		local stop = math.min(frames, index + math.ceil((hop - position) / speed))
		while index < stop and position < hop do
			local left = math.floor(position)
			local a = buffer.readf32(self.grain, left * 4)
			local b = if left + 1 < hop
				then buffer.readf32(self.grain, (left + 1) * 4)
				else buffer.readf32(self.tail, 0)
			fade = math.min(1, fade + fadeStep)
			sample = (a + (b - a) * (position - left)) * volume * fade
			buffer.writef32(output, index * 4, sample)
			index += 1
			position += speed
		end
	end
	self.grainPosition, self.fade, self.lastSample = position, fade, sample
	if index < frames then
		local fadeEnd = math.min(frames, index + self.fadeFrames)
		for tailIndex = index, fadeEnd - 1 do
			buffer.writef32(output, tailIndex * 4, sample * (1 - (tailIndex - index + 1) * fadeStep))
		end
		buffer.fill(output, fadeEnd * 4, 0, (frames - fadeEnd) * 4)
		self.ready, self.hasTail, self.lastSample = false, false, 0
		self.fade, self.grainPosition = 0, hop
		self.underruns += 1
		self.rateInput, self.rateSeconds = 0, 0
		-- Keep a larger reserve after a stall so a bursty guest can recover
		-- without repeatedly starting and stopping audio.
		self.threshold = math.min(self.maxThreshold, self.threshold + self.refillStep)
	end
end

return PcmQueue
