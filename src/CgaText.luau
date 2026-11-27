local band, extract = bit32.band, bit32.extract
local VIDEO_BASE = 0xB8000
local COLUMNS, ROWS = 80, 25
local CELL_SIZE, PIXEL_BYTES = 8, 4
local WIDTH, HEIGHT = COLUMNS * CELL_SIZE, ROWS * CELL_SIZE
local STRIDE = WIDTH * PIXEL_BYTES

local CGA = {
	0x000000,
	0x0000AA,
	0x00AA00,
	0x00AAAA,
	0xAA0000,
	0xAA00AA,
	0xAA5500,
	0xAAAAAA,
	0x555555,
	0x5555FF,
	0x55FF55,
	0x55FFFF,
	0xFF5555,
	0xFF55FF,
	0xFFFF55,
	0xFFFFFF,
}
local palette = table.create(16)
for index, rgb in CGA do
	palette[index] = 0xFF000000 + extract(rgb, 16, 8) + band(rgb, 0x00FF00) + extract(rgb, 0, 8) * 0x10000
end

local CgaText = { WIDTH = WIDTH, HEIGHT = HEIGHT }
CgaText.__index = CgaText

function CgaText.new(font)
	assert(buffer.len(font) == 256 * CELL_SIZE, "Expected an 8×8 font with 256 glyphs")
	return setmetatable({
		font = font,
		pixels = buffer.create(STRIDE * HEIGHT),
		cells = table.create(COLUMNS * ROWS),
	}, CgaText)
end

function CgaText:drawCell(column, row, character, attribute, cursorStart, cursorEnd)
	local foreground = palette[band(attribute, 0xF) + 1]
	local background = palette[extract(attribute, 4, 4) + 1]
	local offset = row * CELL_SIZE * STRIDE + column * CELL_SIZE * PIXEL_BYTES
	for y = 0, CELL_SIZE - 1 do
		local bits = buffer.readu8(self.font, character * CELL_SIZE + y)
		if y >= cursorStart and y <= cursorEnd then
			bits = 0xFF
		end
		local mask = 0x80
		for x = 0, CELL_SIZE - 1 do
			buffer.writeu32(self.pixels, offset + x * PIXEL_BYTES, band(bits, mask) ~= 0 and foreground or background)
			mask = bit32.rshift(mask, 1)
		end
		offset += STRIDE
	end
end

function CgaText:update(bus, board)
	local phase = math.floor(board.pit.now / 596591) % 2
	local visible, blink
	if bus.pc then
		visible, blink = bus.vga:colorTextState()
	else
		visible = band(board.cgaMode, 8) ~= 0 and band(board.cgaMode, 2) == 0
		blink = band(board.cgaMode, 0x20) ~= 0
	end
	if
		self.bus == bus
		and self.memoryVersion == bus.videoVersion
		and self.registerVersion == board.videoVersion
		and self.phase == phase
		and self.visible == visible
		and self.blink == blink
	then
		return nil
	end
	self.bus, self.memoryVersion, self.registerVersion, self.phase = bus, bus.videoVersion, board.videoVersion, phase
	self.visible, self.blink = visible, blink

	local crtc = board.crtc
	local start = buffer.readu8(crtc, 12) * 256 + buffer.readu8(crtc, 13)
	local cursor = band(buffer.readu8(crtc, 14) * 256 + buffer.readu8(crtc, 15), 0x1FFF)
	local cursorControl = buffer.readu8(crtc, 10)
	local cursorMode = extract(cursorControl, 5, 2)
	local cursorTop, cursorBottom = band(cursorControl, 31), band(buffer.readu8(crtc, 11), 31)
	local memory = bus.memory
	local cursorVisible = cursorMode == 0 or (cursorMode >= 2 and phase == 0)
	local first, last = ROWS, -1

	for row = 0, ROWS - 1 do
		for column = 0, COLUMNS - 1 do
			local index = row * COLUMNS + column
			local address = band(start + index, 0x1FFF)
			local character, attribute, cursorStart, cursorEnd = 0, 0, CELL_SIZE, 0
			if visible then
				local cell = buffer.readu16(memory, VIDEO_BASE + 2 * address)
				character, attribute = band(cell, 0xFF), extract(cell, 8, 8)
				if blink and band(attribute, 0x80) ~= 0 then
					attribute = band(attribute, 0x7F)
					if phase ~= 0 then
						attribute = band(attribute, 0x70) + extract(attribute, 4, 3)
					end
				end
				if cursorVisible and address == cursor then
					cursorStart, cursorEnd = cursorTop, cursorBottom
				end
			end

			local key = character + attribute * 256 + cursorStart * 0x10000 + cursorEnd * 0x200000
			if self.cells[index + 1] ~= key then
				self.cells[index + 1] = key
				self:drawCell(column, row, character, attribute, cursorStart, cursorEnd)
				first = math.min(first, row)
				last = row
			end
		end
	end

	if last < first then
		return nil
	end
	local y, height = first * CELL_SIZE, (last - first + 1) * CELL_SIZE
	if height == HEIGHT then
		return y, height, self.pixels
	end
	if self.uploadHeight ~= height then
		self.uploadHeight = height
		self.upload = buffer.create(height * STRIDE)
	end
	buffer.copy(self.upload, 0, self.pixels, y * STRIDE, height * STRIDE)
	return y, height, self.upload
end

return CgaText
