local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local extract, lshift, rshift = bit32.extract, bit32.lshift, bit32.rshift
local byteFill = 0x01010101
local planeMasks, solidOffsets, unpackBits = {}, {}, {}
local unpackPlane1, unpackPlane2, unpackPlane3 = {}, {}, {}
local singlePlanes = { [1] = 0, [2] = 1, [4] = 2, [8] = 3 }
for value = 0, 15 do
	local planes = 0
	for plane = 0, 3 do
		planes += extract(value, plane) * lshift(0xFF, plane * 8)
	end
	planeMasks[value] = planes
	solidOffsets[planes] = value * 32
end
for value = 0, 255 do
	local pixels = 0
	for pixel = 0, 7 do
		pixels += lshift(extract(value, 7 - pixel), pixel * 4)
	end
	unpackBits[value] = pixels
	unpackPlane1[value] = lshift(pixels, 1)
	unpackPlane2[value] = lshift(pixels, 2)
	unpackPlane3[value] = lshift(pixels, 3)
end

local Vga = {
	WIDTH = 320,
	HEIGHT = 200,
	PLANAR_WIDTH = 640,
	PLANAR_HEIGHT = 480,
	MEMORY_BASE = 0xA0000,
	MEMORY_SIZE = 0x10000,
}
-- Track 128-byte chunks of interleaved VRAM so guest writes stay cheap.
local DIRTY_BLOCKS = Vga.MEMORY_SIZE / 32
local MAX_UPLOAD_RECTS = 8
local REPAINT_BLOCK_GROUPS = 32
local MAX_REPAINT_FRAME_SECONDS = 1 / 40

Vga.__index = Vga

function Vga.new()
	return setmetatable({
		memory = buffer.create(4 * Vga.MEMORY_SIZE),
		dac = buffer.create(256 * 3),
		pixels = buffer.create(0),
		upload = buffer.create(0),
		dirtyBlocks = buffer.create(DIRTY_BLOCKS),
		rectangles = {},
		presentedPlanes = buffer.create(0),
		solidColors = buffer.create(16 * 32),
		fullRedraw = true,
		paletteDirty = true,
		colors = table.create(256),
		sequencer = buffer.create(5),
		graphics = buffer.create(9),
		attribute = buffer.create(0x15),
		crtc = buffer.create(0x19),
		crtcIndex = 0,
		attributeIndex = 0,
		attributeData = false,
		attributeVideoEnabled = false,
		miscellaneous = 0,
		latches = 0,
		planes = 0,
		readMap = 0,
		sequencerIndex = 0,
		graphicsIndex = 0,
		pixelMask = 0xFF,
		dacRead = 0,
		dacWrite = 0,
		dacState = 0,
		active = false,
		dirty = true,
	}, Vga)
end

local function updateDirectWrite(self)
	self.directWrite = self.writeMode == 0
		and self.bitMask == 255
		and self.rotate == 0
		and self.operation == 0
		and self.enableSetReset == 0
end

function Vga:updateMode()
	local wasActive, wasIndexed = self.active, self.indexed
	local graphicsMode = buffer.readu8(self.graphics, 5)
	self.chain4 = band(buffer.readu8(self.sequencer, 4), 8) ~= 0
	self.indexed = band(graphicsMode, 0x60) == 0x40
	self.active = band(buffer.readu8(self.graphics, 6), 0x0D) == 5
	self.width = if self.indexed then Vga.WIDTH else Vga.PLANAR_WIDTH
	self.height = if self.indexed then Vga.HEIGHT else Vga.PLANAR_HEIGHT
	self.planes = band(buffer.readu8(self.sequencer, 2), 0x0F)
	self.singlePlane = singlePlanes[self.planes]
	self.writeMode = band(graphicsMode, 3)
	self.readMode = band(graphicsMode, 8) ~= 0
	self.readMap = band(buffer.readu8(self.graphics, 4), 3)
	self.bitMask = buffer.readu8(self.graphics, 8)
	local rotate = buffer.readu8(self.graphics, 3)
	self.rotate = band(rotate, 7)
	self.operation = extract(rotate, 3, 2)
	self.setReset = planeMasks[band(buffer.readu8(self.graphics, 0), 15)]
	self.enableSetReset = planeMasks[band(buffer.readu8(self.graphics, 1), 15)]
	updateDirectWrite(self)
	if self.active ~= wasActive or self.indexed ~= wasIndexed then
		self.fullRedraw = true
		self.paletteDirty = true
		self.dirty = true
	end
end

local function markWrite(self, offset)
	if not self.fullRedraw then
		buffer.writeu8(self.dirtyBlocks, rshift(offset, 7), 1)
	end
	self.dirty = true
end

local function markRange(self, offset, length)
	if not self.fullRedraw then
		local first, last = rshift(offset, 7), rshift(offset + length - 1, 7)
		buffer.fill(self.dirtyBlocks, first, 1, last - first + 1)
	end
	self.dirty = true
end

function Vga:tryCopyChain4(offset, source, start, length)
	if not self.chain4 or not self.directWrite or self.planes ~= 15 then
		return false
	end
	buffer.copy(self.memory, offset, source, start, length)
	markRange(self, offset, length)
	return true
end

-- In planar write mode 1 each destination receives all four source planes
-- from the VGA latches. The last read must remain visible to later writes.
function Vga:tryCopyPlanar(target, source, count, backwards)
	if self.chain4 or self.writeMode ~= 1 or self.planes ~= 15 then
		return false
	end
	local gap = if backwards then source - target else target - source
	if gap > 0 and gap < count then
		return false
	end
	local memory, length = self.memory, count * 4
	self.latches = buffer.readu32(memory, (if backwards then source else source + count - 1) * 4)
	if target ~= source then
		buffer.copy(memory, target * 4, memory, source * 4, length)
		markRange(self, target * 4, length)
	end
	return true
end

-- An aligned four-byte write in standard chain-4 mode targets one
-- byte per plane and has no latch or raster-operation side effects.
function Vga:tryWriteChain4Dword(offset, value)
	if not self.chain4 or not self.directWrite or self.planes ~= 15 then
		return false
	end
	local memory = self.memory
	if buffer.readu32(memory, offset) ~= value then
		buffer.writeu32(memory, offset, value)
		markWrite(self, offset)
	end
	return true
end

function Vga:readMemory(offset)
	local base = if self.chain4 then band(offset, 0xFFFC) else offset * 4
	local latches = buffer.readu32(self.memory, base)
	self.latches = latches
	if self.readMode then
		local care = planeMasks[band(buffer.readu8(self.graphics, 7), 15)]
		local compare = planeMasks[band(buffer.readu8(self.graphics, 2), 15)]
		local differences = band(bxor(latches, compare), care)
		return band(
			bnot(bor(differences, rshift(differences, 8), rshift(differences, 16), rshift(differences, 24))),
			255
		)
	end
	local plane = if self.chain4 then band(offset, 3) else self.readMap
	return extract(latches, plane * 8, 8)
end

function Vga:writeMemory(offset, value)
	local planes, memory = self.planes, self.memory
	if self.chain4 then
		planes = band(planes, lshift(1, band(offset, 3)))
		if planes == 0 then
			return
		end
		if self.directWrite then
			if buffer.readu8(memory, offset) ~= value then
				buffer.writeu8(memory, offset, value)
				markWrite(self, offset)
			end
			return
		end
		offset = band(offset, 0xFFFC)
	else
		offset *= 4
		local plane = self.singlePlane
		if self.directWrite and plane then
			local address = offset + plane
			if buffer.readu8(memory, address) ~= value then
				buffer.writeu8(memory, address, value)
				markWrite(self, offset)
			end
			return
		end
	end
	if planes == 0 then
		return
	end

	local result, latches = 0, self.latches
	local mode = self.writeMode
	if self.directWrite then
		result = value * byteFill
	elseif mode == 1 then
		result = latches
	else
		local rotated = band(bor(rshift(value, self.rotate), lshift(value, 8 - self.rotate)), 255)
		local mask = self.bitMask
		if mode == 0 then
			local enabled = self.enableSetReset
			result = bor(band(rotated * byteFill, bnot(enabled)), band(self.setReset, enabled))
		elseif mode == 2 then
			result = planeMasks[band(value, 15)]
		else
			mask = band(mask, rotated)
			result = self.setReset
		end
		if self.operation == 1 then
			result = band(result, latches)
		elseif self.operation == 2 then
			result = bor(result, latches)
		elseif self.operation == 3 then
			result = bxor(result, latches)
		end
		if mask ~= 255 then
			local bits = mask * byteFill
			result = bor(band(result, bits), band(latches, bnot(bits)))
		end
	end
	local previous = buffer.readu32(memory, offset)
	if planes ~= 15 then
		local selected = planeMasks[planes]
		result = bor(band(result, selected), band(previous, bnot(selected)))
	end
	if result ~= previous then
		buffer.writeu32(memory, offset, result)
		markWrite(self, offset)
	end
end

function Vga:colorTextState()
	local mode = buffer.readu8(self.attribute, 0x10)
	local visible = self.attributeVideoEnabled
		and band(buffer.readu8(self.sequencer, 1), 0x20) == 0
		and band(buffer.readu8(self.graphics, 6), 0x0D) == 0x0C
		and band(mode, 1) == 0
	return visible, band(mode, 8) ~= 0
end

function Vga:readPort(port)
	if port == 0x3DA then
		self.attributeData = false
	elseif port == 0x3C1 then
		return self.attributeIndex < 0x15 and buffer.readu8(self.attribute, self.attributeIndex) or 0xFF
	elseif port == 0x3CC then
		return self.miscellaneous
	elseif port == 0x3C4 then
		return self.sequencerIndex
	elseif port == 0x3C5 then
		return self.sequencerIndex < 5 and buffer.readu8(self.sequencer, self.sequencerIndex) or 0xFF
	elseif port == 0x3CE then
		return self.graphicsIndex
	elseif port == 0x3CF then
		return self.graphicsIndex < 9 and buffer.readu8(self.graphics, self.graphicsIndex) or 0xFF
	elseif port == 0x3C6 then
		return self.pixelMask
	elseif port == 0x3C7 then
		return self.dacState
	elseif port == 0x3C8 then
		return math.floor(self.dacWrite / 3)
	elseif port == 0x3C9 then
		local value = buffer.readu8(self.dac, self.dacRead)
		self.dacRead = (self.dacRead + 1) % 768
		return value
	end
	return nil
end

function Vga:writePort(port, value)
	if port == 0x3D4 then
		self.crtcIndex = band(value, 31)
		return false -- Also deliver CRTC writes to the board's text display.
	elseif port == 0x3D5 then
		local index = self.crtcIndex
		if index < 0x19 and buffer.readu8(self.crtc, index) ~= value then
			buffer.writeu8(self.crtc, index, value)
			if index == 0x0C or index == 0x0D or index == 0x13 then
				self.dirty, self.fullRedraw = true, true
			end
		end
		return false
	elseif port == 0x3C0 then
		if self.attributeData then
			local index = self.attributeIndex
			if index < 0x15 and buffer.readu8(self.attribute, index) ~= value then
				buffer.writeu8(self.attribute, index, value)
				self.dirty, self.fullRedraw, self.paletteDirty = true, true, true
			end
		else
			self.attributeIndex = band(value, 31)
			self.attributeVideoEnabled = band(value, 0x20) ~= 0
		end
		self.attributeData = not self.attributeData
	elseif port == 0x3C2 then
		self.miscellaneous = value
	elseif port == 0x3C4 then
		self.sequencerIndex = band(value, 0x07)
	elseif port == 0x3C5 then
		local index = self.sequencerIndex
		if index < 5 and buffer.readu8(self.sequencer, index) ~= value then
			buffer.writeu8(self.sequencer, index, value)
			if index == 2 then
				self.planes = band(value, 15)
				self.singlePlane = singlePlanes[self.planes]
			elseif index == 4 then
				self.chain4 = band(value, 8) ~= 0
			end
		end
	elseif port == 0x3CE then
		self.graphicsIndex = band(value, 0x0F)
	elseif port == 0x3CF then
		local index = self.graphicsIndex
		if index < 9 and buffer.readu8(self.graphics, index) ~= value then
			buffer.writeu8(self.graphics, index, value)
			if index == 8 then
				self.bitMask = value
				updateDirectWrite(self)
			elseif index == 0 then
				self.setReset = planeMasks[band(value, 15)]
			elseif index == 1 then
				self.enableSetReset = planeMasks[band(value, 15)]
				updateDirectWrite(self)
			elseif index == 3 then
				self.rotate, self.operation = band(value, 7), extract(value, 3, 2)
				updateDirectWrite(self)
			elseif index == 4 then
				self.readMap = band(value, 3)
			elseif index == 5 or index == 6 then
				self:updateMode()
			end
		end
	elseif port == 0x3C6 then
		if self.pixelMask ~= value then
			self.pixelMask = value
			self.dirty, self.fullRedraw, self.paletteDirty = true, true, true
		end
	elseif port == 0x3C7 then
		self.dacRead, self.dacState = value * 3, 3
	elseif port == 0x3C8 then
		self.dacWrite, self.dacState = value * 3, 0
	elseif port == 0x3C9 then
		local channel = band(value, 0x3F)
		if buffer.readu8(self.dac, self.dacWrite) ~= channel then
			buffer.writeu8(self.dac, self.dacWrite, channel)
			self.dirty, self.fullRedraw, self.paletteDirty = true, true, true
		end
		self.dacWrite = (self.dacWrite + 1) % 768
	else
		return false
	end
	return true
end

local function expand(channel)
	return channel * 4 + rshift(channel, 4)
end

function Vga:updatePalette()
	local dac, colors, indexed = self.dac, self.colors, self.indexed
	local attribute = self.attribute
	local planeEnable = band(buffer.readu8(attribute, 0x12), 15)
	local colorSelect = buffer.readu8(attribute, 0x14)
	local override = band(buffer.readu8(attribute, 0x10), 0x80) ~= 0
	for index = 0, indexed and 255 or 15 do
		local color = index
		if not indexed then
			color = band(buffer.readu8(attribute, band(index, planeEnable)), 63)
			if override then
				color = band(color, 15) + band(colorSelect, 3) * 16
			end
			color += band(colorSelect, 12) * 16
		end
		local offset = band(color, self.pixelMask) * 3
		local red = expand(buffer.readu8(dac, offset))
		local green = expand(buffer.readu8(dac, offset + 1))
		local blue = expand(buffer.readu8(dac, offset + 2))
		local rgba = 0xFF000000 + blue * 0x10000 + green * 0x100 + red
		colors[index] = rgba
		if not indexed then
			for offset = index * 32, index * 32 + 28, 4 do
				buffer.writeu32(self.solidColors, offset, rgba)
			end
		end
	end
	self.paletteDirty = false
end

local function dirtySpan(blocks, address, columns)
	local first, last
	for block = rshift(address, 5), rshift(address + columns - 1, 5) do
		if buffer.readu8(blocks, band(block, DIRTY_BLOCKS - 1)) ~= 0 then
			first = first or block
			last = block
		end
	end
	if first then
		return math.max(0, first * 32 - address), math.min(columns, (last + 1) * 32 - address)
	end
	return nil
end

local function drawIndexed(memory, pixels, colors, source, destination, length)
	for offset = source, source + length - 4, 4 do
		local indices = buffer.readu32(memory, offset)
		buffer.writeu32(pixels, destination, colors[band(indices, 255)])
		buffer.writeu32(pixels, destination + 4, colors[extract(indices, 8, 8)])
		buffer.writeu32(pixels, destination + 8, colors[extract(indices, 16, 8)])
		buffer.writeu32(pixels, destination + 12, colors[extract(indices, 24, 8)])
		destination += 16
	end
end

local function drawPlanarGroup(pixels, colors, solidColors, destination, planes)
	local solid = solidOffsets[planes]
	if solid then
		buffer.copy(pixels, destination, solidColors, solid, 32)
		return
	end
	local indices = bor(
		unpackBits[band(planes, 255)],
		unpackPlane1[extract(planes, 8, 8)],
		unpackPlane2[extract(planes, 16, 8)],
		unpackPlane3[extract(planes, 24, 8)]
	)
	buffer.writeu32(pixels, destination, colors[band(indices, 15)])
	buffer.writeu32(pixels, destination + 4, colors[extract(indices, 4, 4)])
	buffer.writeu32(pixels, destination + 8, colors[extract(indices, 8, 4)])
	buffer.writeu32(pixels, destination + 12, colors[extract(indices, 12, 4)])
	buffer.writeu32(pixels, destination + 16, colors[extract(indices, 16, 4)])
	buffer.writeu32(pixels, destination + 20, colors[extract(indices, 20, 4)])
	buffer.writeu32(pixels, destination + 24, colors[extract(indices, 24, 4)])
	buffer.writeu32(pixels, destination + 28, colors[extract(indices, 28, 4)])
end

local function drawSpan(vga, address, screenGroup, groups)
	local memory, pixels, colors = vga.memory, vga.pixels, vga.colors
	while groups > 0 do
		local count = math.min(groups, Vga.MEMORY_SIZE - address)
		local source, length = address * 4, count * 4
		if vga.indexed then
			drawIndexed(memory, pixels, colors, source, screenGroup * 16, length)
		else
			-- Track the last presented planes in screen order, including when
			-- a CRTC stride makes two rows use the same VRAM addresses.
			buffer.copy(vga.presentedPlanes, screenGroup * 4, memory, source, length)
			local destination = screenGroup * 32
			for offset = source, source + length - 4, 4 do
				drawPlanarGroup(pixels, colors, vga.solidColors, destination, buffer.readu32(memory, offset))
				destination += 32
			end
		end
		groups -= count
		screenGroup += count
		address = 0
	end
end

local function drawChangedPlanar(vga, address, screenRow, first, last)
	local memory, previous, pixels = vga.memory, vga.presentedPlanes, vga.pixels
	local colors, solidColors = vga.colors, vga.solidColors
	local firstChange, lastChange
	for column = first, last - 1 do
		local source = band(address + column, 0xFFFF) * 4
		local screenGroup = screenRow + column
		local planes = buffer.readu32(memory, source)
		if planes ~= buffer.readu32(previous, screenGroup * 4) then
			buffer.writeu32(previous, screenGroup * 4, planes)
			drawPlanarGroup(pixels, colors, solidColors, screenGroup * 32, planes)
			firstChange = firstChange or column
			lastChange = column + 1
		end
	end
	return firstChange, lastChange
end

local function mergeNearestRows(rectangles, last)
	-- Share the upload budget between separated updates, such as a mouse
	-- cursor moving between two windows on opposite sides of the screen.
	local best, leastExtra = 1, math.huge
	for index = 1, last - 7, 4 do
		local left, top, right, bottom =
			rectangles[index], rectangles[index + 1], rectangles[index + 2], rectangles[index + 3]
		local nextLeft, nextTop, nextRight, nextBottom =
			rectangles[index + 4], rectangles[index + 5], rectangles[index + 6], rectangles[index + 7]
		local mergedWidth = math.max(right, nextRight) - math.min(left, nextLeft)
		local extra = mergedWidth * (nextBottom - top)
			- (right - left) * (bottom - top)
			- (nextRight - nextLeft) * (nextBottom - nextTop)
		if extra < leastExtra then
			best, leastExtra = index, extra
		end
	end
	rectangles[best] = math.min(rectangles[best], rectangles[best + 4])
	rectangles[best + 2] = math.max(rectangles[best + 2], rectangles[best + 6])
	rectangles[best + 3] = rectangles[best + 7]
	table.move(rectangles, best + 8, last, best + 4)
	for index = last - 3, last do
		rectangles[index] = nil
	end
end

-- Rectangles store left, top, right, bottom, with exclusive right/bottom edges.
local function addRow(rectangles, left, y, right)
	local last = #rectangles
	if rectangles[last] == y and left <= rectangles[last - 1] and right >= rectangles[last - 3] then
		rectangles[last - 3] = math.min(left, rectangles[last - 3])
		rectangles[last - 1] = math.max(right, rectangles[last - 1])
		rectangles[last] = y + 1
	else
		rectangles[last + 1], rectangles[last + 2] = left, y
		rectangles[last + 3], rectangles[last + 4] = right, y + 1
		if last == MAX_UPLOAD_RECTS * 4 then
			mergeNearestRows(rectangles, last + 4)
		end
	end
end

function Vga:shouldDelayPresent(elapsed, cpuBusy, dragging)
	if self.indexed or self.fullRedraw or self.delayedPresent or not self.dirty or not cpuBusy or dragging then
		return false
	end
	if elapsed > MAX_REPAINT_FRAME_SECONDS then
		return false
	end
	-- A busy planar guest can erase its software cursor before painting a
	-- window. Hold large updates for one frame so the next slice can finish it.
	local groups = 0
	for offset = 0, DIRTY_BLOCKS - 4, 4 do
		if buffer.readu32(self.dirtyBlocks, offset) ~= 0 then
			groups += 1
			if groups >= REPAINT_BLOCK_GROUPS then
				self.delayedPresent = true
				return true
			end
		end
	end
	return false
end

function Vga:render()
	self.delayedPresent = false
	if not self.active or not self.dirty then
		return nil
	end
	if self.paletteDirty then
		self:updatePalette()
	end
	local width, height = self.width, self.height
	local size = width * height * 4
	local indexed = self.indexed
	if buffer.len(self.pixels) ~= size then
		self.pixels = buffer.create(size)
		self.fullRedraw = true
	end
	if not indexed and buffer.len(self.presentedPlanes) == 0 then
		self.presentedPlanes = buffer.create(width * height / 2)
	end

	local crtc = self.crtc
	local base = buffer.readu8(crtc, 0x0C) * 256 + buffer.readu8(crtc, 0x0D)
	local stride = buffer.readu8(crtc, 0x13) * 2
	local groupWidth = if indexed then 4 else 8
	local columns = width / groupWidth
	if stride == 0 then
		stride = columns
	end

	local rectangles = self.rectangles
	table.clear(rectangles)
	if self.fullRedraw then
		if stride == columns then
			drawSpan(self, base, 0, columns * height)
		else
			for y = 0, height - 1 do
				drawSpan(self, band(base + y * stride, 0xFFFF), y * columns, columns)
			end
		end
		rectangles[1], rectangles[2], rectangles[3], rectangles[4] = 0, 0, width, height
	else
		for y = 0, height - 1 do
			local address = band(base + y * stride, 0xFFFF)
			local first, last = dirtySpan(self.dirtyBlocks, address, columns)
			if first then
				local screenRow = y * columns
				if indexed then
					drawSpan(self, band(address + first, 0xFFFF), screenRow + first, last - first)
				else
					first, last = drawChangedPlanar(self, address, screenRow, first, last)
				end
				if first then
					addRow(rectangles, first * groupWidth, y, last * groupWidth)
				end
			end
		end
	end

	buffer.fill(self.dirtyBlocks, 0, 0)
	self.dirty, self.fullRedraw = false, false

	return self.pixels, rectangles
end

function Vga:pixelsForRect(x, y, width, height)
	if width == self.width and height == self.height then
		return self.pixels
	end
	local rowBytes = width * 4
	local size = rowBytes * height
	if buffer.len(self.upload) ~= size then
		self.upload = buffer.create(size)
	end
	local stride = self.width * 4
	local source = y * stride + x * 4
	if width == self.width then
		buffer.copy(self.upload, 0, self.pixels, source, size)
	else
		for row = 0, height - 1 do
			buffer.copy(self.upload, row * rowBytes, self.pixels, source + row * stride, rowBytes)
		end
	end
	return self.upload
end

return Vga
