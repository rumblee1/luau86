local PcmQueue = require("../src/PcmQueue")

local inputRate, outputRate = 24000, 48000
local queue = PcmQueue.new(inputRate, outputRate)
local position = 0
local function tone(count)
	local samples = buffer.create(count * 4)
	for i = 0, count - 1 do
		local sample = math.sin((position + i) * (2 * math.pi * 1000 / inputRate))
		buffer.writef32(samples, i * 4, sample)
	end
	position += count
	return samples
end

local sourceFrames = { 240, 560, 288, 528, 400, 384 }
local writerFrames = { 816, 784, 816, 784, 816, 784 }
queue:push(tone(1300), 1300, 0)
local consecutive, crossings, total, maxJump = 0, 0, 0, 0
for round = 1, 300 do
	local index = (round - 1) % #sourceFrames + 1
	local count, frames = sourceFrames[index], writerFrames[index]
	queue:push(tone(count), count, frames / outputRate)
	local output = buffer.create(frames * 4)
	queue:render(output, frames, 1)
	for i = 0, frames - 1 do
		local sample = buffer.readf32(output, i * 4)
		if consecutive <= 0 and sample > 0 then
			crossings += 1
		end
		maxJump = math.max(maxJump, math.abs(sample - consecutive))
		consecutive = sample
	end
	total += frames
end
local hz = crossings * outputRate / total
assert(math.abs(hz - 1000) < 20, hz)
assert(maxJump < 0.14 and queue.underruns == 0 and queue.dropped == 0, maxJump)

local outage = buffer.create(10000 * 4)
queue:render(outage, 10000, 1)
assert(queue.underruns == 1 and buffer.readf32(outage, 39996) == 0)
queue:render(outage, 10000, 1)
assert(queue.underruns == 1 and buffer.readf32(outage, 0) == 0)
queue:push(tone(queue.threshold), queue.threshold, 0)
queue:render(outage, 1200, 0.5)
assert(math.abs(buffer.readf32(outage, 0)) < 0.01 and queue.ready)

queue:push(tone(queue.capacity * 2), queue.capacity * 2, 0)
assert(queue.count == queue.capacity and queue.dropped >= queue.capacity)
print(
	string.format(
		"A 1 kHz tone measured %.1f Hz across uneven frames with no drops; buffering recovered after a stall.",
		hz
	)
)

local slow = PcmQueue.new(inputRate, outputRate)
slow:push(tone(1800), 1800, 0)
local previous, slowCrossings, totalSlow = 0, 0, 0
for frame = 1, 360 do
	local count = if frame % 2 == 0 then 440 else 216
	local output = buffer.create(800 * 4)
	slow:push(tone(count), count, 800 / outputRate)
	slow:render(output, 800, 1)
	for index = 0, 799 do
		local sample = buffer.readf32(output, index * 4)
		if previous <= 0 and sample > 0 then
			slowCrossings += 1
		end
		previous = sample
	end
	totalSlow += 800
end
local slowHz = slowCrossings * outputRate / totalSlow
assert(
	math.abs(slowHz - 1000) < 20 and slow.underruns == 0 and slow.dropped == 0,
	string.format("%.2f Hz, %d underruns, %d dropped", slowHz, slow.underruns, slow.dropped)
)
print(string.format("At 82%% guest speed the same tone measured %.1f Hz, with no underruns.", slowHz))

-- The writer can stay full between calls or run dry during a long frame.
-- Neither case should change how we measure the guest's production rate.
local uneven = PcmQueue.new(inputRate, outputRate)
uneven:push(tone(1800), 1800, 0)
uneven:render(buffer.create(800 * 4), 800, 1)
uneven:push(tone(460), 460, 0.1)
uneven:push(tone(980), 980, 0.05)
local expectedTempo = 1 + (0.4 - 1) * 0.55
assert(math.abs(uneven.tempo - expectedTempo) < 1e-9, "Tempo must use elapsed time even without a writer refill")

local burst = PcmQueue.new(inputRate, outputRate)
for frame = 1, 360 do
	local index = frame % 60
	local elapsed = if index == 25 then 0.064 elseif index == 27 then 0.045 else 1 / 60
	local count = if elapsed > 0.04 then 408 else 372
	local frames = if frame == 1 then 3072 elseif index == 25 then 3648 else math.round(elapsed * outputRate)
	burst:push(tone(count), count, elapsed)
	burst:render(buffer.create(frames * 4), frames, 1)
end
assert(burst.underruns == 0 and burst.dropped == 0, "Uneven client refills must not deplete the guest reserve")
print("PCM stayed continuous through repeated 64 ms and 45 ms refill gaps.")

-- A guest that runs below the previous 35% tempo floor is still producing
-- audio. Stretch that audio across the output instead of refilling in bursts.
local heavilyLoaded = PcmQueue.new(inputRate, outputRate)
local output = buffer.create(800 * 4)
for _ = 1, 120 do
	heavilyLoaded:push(tone(400), 400, 1 / 60)
	heavilyLoaded:render(output, 800, 1)
end
local playing, playedFrames, slowCrossings, lastSample = false, 0, 0, 0
for frame = 1, 600 do
	local count = if frame % 2 == 0 then 136 else 64
	heavilyLoaded:push(tone(count), count, 1 / 60)
	heavilyLoaded:render(output, 800, 1)
	if heavilyLoaded.ready then
		playing = true
		playedFrames += 800
		for offset = 0, buffer.len(output) - 4, 4 do
			local sample = buffer.readf32(output, offset)
			if lastSample <= 0 and sample > 0 then
				slowCrossings += 1
			end
			lastSample = sample
		end
	end
end
local loadedHz = slowCrossings * outputRate / playedFrames
assert(playing and heavilyLoaded.underruns == 0 and heavilyLoaded.dropped == 0, heavilyLoaded.underruns)
assert(math.abs(loadedHz - 1000) < 20, loadedHz)
print(
	string.format(
		"At 25%% guest speed a 1 kHz tone measured %.1f Hz without underruns after playback started.",
		loadedHz
	)
)
