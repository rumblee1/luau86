local PcmWriter = require("../src/PcmWriter")

local pcm = PcmWriter.new(1000)
local samples, rendered = {}, 0
local writer = { limit = 2 }
function writer:Write(channels)
	local output = channels[1]
	local count = math.min(self.limit, buffer.len(output) / 4)
	for frame = 0, count - 1 do
		table.insert(samples, buffer.readf32(output, frame * 4))
	end
	return count
end

local queue = {}
function queue:render(output, count)
	for frame = 0, count - 1 do
		rendered += 1
		buffer.writef32(output, frame * 4, rendered)
	end
end

-- Refill in four-frame blocks, then force partial and zero writes.
assert(pcm:refill(writer, queue, 16, 5, 1) == 14 and rendered == 8)
writer.limit = 0
assert(pcm:refill(writer, queue, 16, 5, 1) == 16 and rendered == 8)
writer.limit = 16
assert(pcm:refill(writer, queue, 3, 3, 1) == 0 and rendered == 8)
assert(pcm:refill(writer, queue, 0, 0, 1) == 0 and rendered == 8)
assert(pcm:refill(writer, queue, 16, 7, 1) == 9 and rendered == 12)
assert(pcm:refill(writer, queue, 3, 3, 1) == 0 and rendered == 15)
for index = 1, 15 do
	assert(samples[index] == index, "The writer must play each rendered frame in order")
end
assert(#samples == 15)
print("PCM writes preserved sample order through short writes and a full writer")
