local PcmWriter = {}
PcmWriter.__index = PcmWriter

function PcmWriter.new(rate)
	return setmetatable({
		blockFrames = math.max(1, math.round(rate * 0.004)),
		blocks = {},
		channels = {},
		pending = nil,
		offset = 0,
	}, PcmWriter)
end

function PcmWriter:refill(writer, queue, space, frames, volume)
	if space == 0 then
		return space
	end
	-- Finish a partial write before rendering any more guest samples.
	local pending = self.pending
	if pending then
		local remaining = buffer.len(pending) / 4 - self.offset
		local count = math.min(space, remaining)
		local bytes = count * 4
		local suffix = self.suffix
		if not suffix or buffer.len(suffix) ~= bytes then
			suffix = buffer.create(bytes)
			self.suffix = suffix
		end
		buffer.copy(suffix, 0, pending, self.offset * 4, bytes)
		self.channels[1] = suffix
		local written = writer:Write(self.channels)
		space -= written
		frames -= written
		if written < remaining then
			self.offset += written
			return space
		end
		self.pending, self.offset = nil, 0
	end

	if frames > 0 then
		local blocks = math.ceil(frames / self.blockFrames)
		local rounded = blocks * self.blockFrames
		local count = math.min(rounded, space)
		local output
		if count == rounded then
			output = self.blocks[blocks]
			if not output then
				output = buffer.create(count * 4)
				self.blocks[blocks] = output
			end
		else
			output = self.unrounded
			if not output or buffer.len(output) ~= count * 4 then
				output = buffer.create(count * 4)
				self.unrounded = output
			end
		end
		queue:render(output, count, volume)
		self.channels[1] = output
		local written = writer:Write(self.channels)
		if written < count then
			self.pending, self.offset = output, written
		end
		space -= written
	end
	return space
end

return PcmWriter
