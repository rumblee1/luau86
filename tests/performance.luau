local FrameBudget = require("../src/FrameBudget")
local Machine = require("../src/Machine")
local decode = require("../src/MediaDecode")

local scheduler = FrameBudget.new(Machine.PIT_HZ)
for _ = 1, 10 do
	local credit, budget = scheduler:beginFrame(1 / 60, true)
	assert(budget == 0.004)
	scheduler:endFrame(credit, 0.002, 0)
end
for _, rate in { 60, 50, 30 } do
	for _ = 1, 120 do
		local credit, budget = scheduler:beginFrame(1 / rate, true)
		assert(credit <= Machine.PIT_HZ / 10, "Catch-up must remain bounded")
		assert(budget >= 0.002 and budget <= 0.012)
		scheduler:endFrame(100, budget, 0)
	end
	local limit = math.min(0.012, 0.5 / rate)
	assert(math.abs(scheduler.budget - limit) < 1e-8, "A lagging guest needs a share of slow and fast frames")
end
scheduler:endFrame(0, scheduler.budget, 0.008)
local _, repaintBudget = scheduler:beginFrame(1 / 30, true)
assert(math.abs(repaintBudget - 0.004) < 1e-9, "A slow repaint must reserve time before the next slice")
for _ = 1, 120 do
	local _, budget = scheduler:beginFrame(1 / 30, true)
	scheduler:endFrame(100, budget, 0)
end
assert(math.abs(scheduler.budget - 0.012) < 1e-9, "Repaint reserve must decay")
local frameTime = scheduler.frameTime
local resumedCredit, _ = scheduler:beginFrame(1, true)
assert(
	scheduler.frameTime == frameTime and resumedCredit <= Machine.PIT_HZ / 10,
	"Pauses must not amplify the estimate"
)
local _, fixedBudget = scheduler:beginFrame(1 / 30, false)
assert(fixedBudget == 0.004, "The baseline should use the fixed budget")
print("Adaptive budget kept working at 30–60 FPS, reserved time for repaint, and bounded catch-up")

local indexed = FrameBudget.new(Machine.PIT_HZ)
for _ = 1, 120 do
	local _, budget = indexed:beginFrame(1 / 30, true, true)
	indexed:endFrame(100, budget, 0.002)
end
assert(math.abs(indexed.budget - 0.014) < 1e-8, "Indexed VGA must reserve time for the display")
local _, planarBudget = indexed:beginFrame(1 / 30, true, false)
assert(math.abs(planarBudget - 0.010) < 1e-8, "Planar VGA must return to the regular CPU budget")

local Pit = require("../src/Pit8253")
local interrupts = 0
local pit = Pit.new(function()
	interrupts += 1
end)
assert(pit:clocksUntilIrq() == math.huge)
pit:write(0x43, 0x10)
pit:write(0x40, 7)
pit:advance(6)
assert(interrupts == 0 and pit:clocksUntilIrq() == 1)
pit:advance(2)
assert(interrupts == 1 and pit:clocksUntilIrq() == math.huge)
pit:advance(90)
assert(interrupts == 1)
pit:write(0x43, 0x14)
pit:write(0x40, 16)
pit:advance(33)
assert(interrupts == 2 and pit:clocksUntilIrq() == 15, "A batch must keep the PIT period aligned")
pit:write(0x43, 0)
assert(pit:clocksUntilIrq() == 15, "Latching a reading must preserve the pending IRQ")
pit:write(0x43, 0x14)
pit:advance(15)
assert(interrupts == 2 and pit:clocksUntilIrq() == math.huge, "Reprogramming the PIT stops the old timer")
pit:write(0x40, 16)
pit:advance(16)
assert(interrupts == 3 and pit:clocksUntilIrq() == 16)
pit:write(0x43, 0x54)
pit:write(0x41, 4)
assert(pit:advance(3) == 0, "DMA refresh must wait for its deadline")
assert(pit:advance(10) == 3 and pit:clocksUntilIrq() == 3, "DMA refresh must retain its own period")
pit:write(0x43, 0x50)
assert(pit:advance(3) == 0 and interrupts == 4, "Reprogramming refresh must leave the IRQ timer running")
print("PIT deadlines preserved one-shot, periodic, latch, and reprogramming behavior")

local media = "../src/media/"
local rom, disk, atRom =
	decode(require(media .. "Bios")), decode(require(media .. "Disk")), decode(require(media .. "AtBios"))

local function program(bytes, count, source, target, interrupts)
	local machine = Machine.new(rom, disk, nil, nil, atRom)
	local cpu, memory = machine.cpu, machine.bus.memory
	cpu:loadSegment(2, 0)
	cpu.ip = 0x500
	buffer.writestring(memory, 0x500, bytes)
	cpu:setRegister(1, true, count)
	cpu:setRegister(4, true, 0x7000)
	cpu:setRegister(6, true, source)
	cpu:setRegister(7, true, target)
	cpu.flags = if interrupts then 0x202 else 2
	return machine, cpu, memory
end

local movsb = string.char(0xF3, 0xA4)
local machine, cpu, memory = program(movsb, 80, 0x2000, 0x3000, true)
local source = string.rep("01234567", 10)
buffer.writestring(memory, 0x2000, source)
machine:step()
assert(machine.board.pit.now == 64 and cpu.ip == 0x500 and cpu:getRegister(1, true) == 16)
machine:step()
assert(machine.board.pit.now == 80 and cpu.ip == 0x502 and buffer.readstring(memory, 0x3000, 80) == source)

machine, cpu, memory = program(string.char(0x66, 0xF3, 0xAB), 12, 0, 0x3012, false)
cpu:setRegister(0, 32, 0x7F112233)
machine:step()
assert(machine.board.pit.now == 12 and cpu:getRegister(7, true) == 0x3042)
for offset = 0x3012, 0x3041, 4 do
	assert(buffer.readu32(memory, offset) == 0x7F112233)
end

machine, cpu, memory = program(movsb, 4, 0x2000, 0x2001, true)
buffer.writestring(memory, 0x2000, "ABCDE")
for _ = 1, 4 do
	machine:step()
end
assert(buffer.readstring(memory, 0x2000, 5) == "AAAAA", "An overlapping forward copy must see its own writes")

machine, cpu, memory = program(movsb, 2, 0x2000, 0xFFFF, true)
buffer.writestring(memory, 0x2000, "AB")
machine:step()
machine:step()
assert(buffer.readu8(memory, 0xFFFF) == 65 and buffer.readu8(memory, 0) == 66, "A 16-bit index must wrap")

machine, cpu, memory = program(string.char(0xF3, 0xAA), 4, 0, 0x000E, true)
cpu:loadSegment(1, 0xFFFF)
cpu:setRegister(0, false, 0x34)
for _ = 1, 4 do
	if cpu:getRegister(1, true) == 0 then
		break
	end
	machine:step()
end
assert(buffer.readu16(memory, 0) == 0x3434, "A20 wrap must still map writes to low RAM")

machine.bus.a20 = true
cpu:writeLinear(0x100003, 4, 0xA1B2C3D4)
assert(cpu:readLinear(0x100003, 4) == 0xA1B2C3D4)
machine.bus.a20 = false
buffer.writeu32(memory, 3, 0x12345678)
assert(cpu:readLinear(0x100003, 4) == 0x12345678, "Unpaged extended memory still respects A20")

machine, cpu, memory = program(movsb, 2, 0x2000, 0x500, true)
buffer.writeu8(memory, 0x2000, 0xF4)
machine:step()
assert(cpu:getRegister(1, true) == 1)
machine:step()
assert(cpu.halted, "A write to the running instruction must be visible on the next fetch")

machine, cpu, memory = program(movsb, 32, 0x2000, 0x3000, true)
machine.bus:writePort(0x21, 0xFE)
machine.bus:writePort(0x43, 0x30)
machine.bus:writePort(0x40, 7)
machine.bus:writePort(0x40, 0)
buffer.writeu16(memory, 8 * 4, 0x600)
buffer.writeu8(memory, 0x600, 0xF4)
machine:step()
assert(machine.board.pit.now == 7 and cpu:getRegister(1, true) == 25 and cpu.ip == 0x500)
machine:step()
assert(cpu.halted and buffer.readu16(memory, 0x6FFA) == 0x500, "A PIT IRQ must resume at the REP prefix")
print("386 REP verified RAM copies, fills, overlap, address and A20 wraps, self-modifying code, and IRQ boundaries")

-- An invalid opcode must save its start IP, then yield back to the slice
-- loop so the handler and its new clock deadline are respected.
machine, cpu, memory = program(string.char(0x0F, 0xFF), 0, 0, 0, false)
buffer.writeu16(memory, 6 * 4, 0x600)
buffer.writestring(memory, 0x600, string.char(0x40, 0xF4)) -- INC AX; HLT
assert(not machine:runSlice(1, math.huge))
assert(cpu.ip == 0x600 and machine.board.pit.now == 1)
assert(buffer.readu16(memory, 0x6FFA) == 0x500)
assert(not machine:runSlice(34, math.huge))
assert(cpu.halted and cpu:getRegister(0, true) == 1 and machine.board.pit.now == 34)
assert(not machine:runSlice(100, math.huge) and machine.board.pit.now == 100)

machine = Machine.newSeaBios(buffer.create(0x40000), buffer.create(1))
cpu, memory = machine.cpu, machine.bus.memory
cpu:loadSegment(2, 0)
cpu.ip = 0x500
cpu:setRegister(0, false, 6)
cpu:setRegister(2, true, 0xCF9)
buffer.writeu8(memory, 0x500, 0xEE) -- OUT DX, AL
local oldBoard = machine.board
assert(machine:runSlice(64, math.huge) and machine.board ~= oldBoard and machine.board.pit.now == 0)
print("386 slices preserved the fault IP, handler timing, halt deadline, and hardware reset")

local bus, vga = machine.bus, machine.bus.vga
local function register(port, index, value)
	bus:writePort(port, index)
	bus:writePort(port + 1, value)
end
register(0x3C4, 4, 8) -- Chain-4
register(0x3C4, 2, 15) -- Write all planes
register(0x3CE, 5, 0x40) -- Indexed 256-color mode, write mode 0
register(0x3CE, 6, 5) -- A0000 aperture
register(0x3CE, 8, 0xFF)
assert(vga.active and vga.indexed and vga.chain4 and vga.directWrite)
vga:render()
bus:writePhysical32(0xA0000, 0x44332211)
assert(buffer.readu32(vga.memory, 0) == 0x44332211 and vga:render())
bus:writePhysical32(0xA0000, 0x44332211)
assert(vga:render() == nil, "An unchanged dword must not invalidate VGA")

register(0x3C4, 2, 5) -- Disable planes 1 and 3.
bus:writePhysical32(0xA0000, 0x88776655)
assert(buffer.readu32(vga.memory, 0) == 0x44772255)
register(0x3C4, 2, 15)
register(0x3CE, 8, 0)
vga.latches = 0x12345678
bus:writePhysical32(0xA0000, 0xFFFFFFFF)
assert(buffer.readu32(vga.memory, 0) == 0x12345678, "Masked writes must still use the VGA latches")
print("Aligned VGA dword writes preserved dirty tracking, plane masks, and latch behavior")

local function prepareCopy(planes, count, destination)
	local emulator, processor, ram = program(string.char(0x66, 0xF3, 0xA5), count, 0x2000, destination, true)
	emulator.bus:mountVgaRom(buffer.create(1))
	local display = emulator.bus.vga
	buffer.writeu8(display.sequencer, 4, 8)
	buffer.writeu8(display.sequencer, 2, planes)
	buffer.writeu8(display.graphics, 5, 0x40)
	buffer.writeu8(display.graphics, 6, 5)
	buffer.writeu8(display.graphics, 8, 0xFF)
	display:updateMode()
	display:render()
	processor:loadSegment(1, 0xA000)
	return emulator, processor, ram, display
end

local display
machine, cpu, memory, display = prepareCopy(15, 100, 123)
local pattern = string.rep(string.char(11, 22, 33, 44), 100)
buffer.writestring(memory, 0x2000, pattern)
machine:step()
assert(cpu.ip == 0x500 and cpu:getRegister(1, true) == 36 and machine.board.pit.now == 64)
assert(buffer.readstring(display.memory, 123, 256) == pattern:sub(1, 256))
local _, rectangles = display:render()
assert(rectangles and rectangles[1] == 0 and rectangles[3] == 320 and rectangles[4] == 2)
machine:step()
assert(cpu.ip == 0x503 and cpu:getRegister(1, true) == 0 and machine.board.pit.now == 100)
assert(buffer.readstring(display.memory, 123, 400) == pattern)

machine, cpu, memory, display = prepareCopy(15, 12, 0)
buffer.writestring(memory, 0x2000, pattern)
machine.bus:writePort(0x21, 0xFE)
machine.bus:writePort(0x43, 0x30)
machine.bus:writePort(0x40, 7)
machine.bus:writePort(0x40, 0)
buffer.writeu16(memory, 8 * 4, 0x600)
buffer.writeu8(memory, 0x600, 0xF4)
machine:step()
assert(machine.board.pit.now == 7 and cpu:getRegister(1, true) == 5 and cpu.ip == 0x500)
assert(buffer.readstring(display.memory, 0, 28) == pattern:sub(1, 28) and buffer.readu32(display.memory, 28) == 0)
machine:step()
assert(cpu.halted and buffer.readu16(memory, 0x6FFA) == 0x500)

machine, cpu, memory, display = prepareCopy(5, 2, 0xFFFC)
buffer.writestring(memory, 0x2000, pattern)
machine:step()
assert(cpu:getRegister(1, true) == 1 and buffer.readu32(display.memory, 0xFFFC) == 0x0021000B)
machine:step()
assert(cpu:getRegister(1, true) == 0 and buffer.readu32(display.memory, 0) == 0x0021000B)
print("REP MOVSD to VGA preserved partial copies, IRQ boundaries, plane masks, and 16-bit wrap")

local Vga = require("../src/Vga")
display = Vga.new()
buffer.writeu8(display.sequencer, 2, 15)
buffer.writeu8(display.graphics, 6, 5)
buffer.writeu8(display.graphics, 8, 255)
display:updateMode()
display:render()
local changes = {}
for index = 0, 11 do
	local y = index * 36
	local column = if index % 2 == 0 then 2 else 70
	display:writeMemory(y * 80 + column, index + 1)
	table.insert(changes, { column * 8, y })
end
_, rectangles = display:render()
local area = 0
for index = 1, #rectangles, 4 do
	area += (rectangles[index + 2] - rectangles[index]) * (rectangles[index + 3] - rectangles[index + 1])
end
assert(#rectangles <= 8 * 4 and area < 640 * 480 / 2, "Separate planar updates should share the upload budget")
for _, position in changes do
	local x, y = position[1], position[2]
	local covered = false
	for index = 1, #rectangles, 4 do
		covered = covered
			or (
				x >= rectangles[index]
				and x + 8 <= rectangles[index + 2]
				and y >= rectangles[index + 1]
				and y < rectangles[index + 3]
			)
	end
	assert(covered, "Every changed pixel must be covered by the upload rectangles")
end
print(string.format("Scattered planar updates fit in %d rectangles covering %d pixels", #rectangles / 4, area))

local CgaText = require("../src/CgaText")
local font = buffer.create(256 * 8)
buffer.writeu8(font, 65 * 8, 0x80)
local renderer = CgaText.new(font)
machine = Machine.newSeaBios(buffer.create(0x40000), buffer.create(1))
local textBus, textBoard = machine.bus, machine.board
textBus.vga.attributeVideoEnabled = true
buffer.writeu8(textBus.vga.graphics, 6, 0x0C)
buffer.writeu8(textBus.vga.attribute, 0x10, 8)
textBus.vga:updateMode()
buffer.writeu8(textBoard.crtc, 0x0C, 0x1F)
buffer.writeu8(textBoard.crtc, 0x0D, 0xFF)
buffer.writeu8(textBoard.crtc, 0x0A, 0x20) -- Hide the hardware cursor.
textBus:write8(0xBBFFE, 65)
textBus:write8(0xBBFFF, 0x87)
textBus:write8(0xB8000, 65)
textBus:write8(0xB8001, 2)
assert(renderer:update(textBus, textBoard))
assert(buffer.readu32(renderer.pixels, 0) == 0xFFAAAAAA)
assert(buffer.readu32(renderer.pixels, 8 * 4) == 0xFF00AA00)
textBoard.pit.now = 596591
assert(renderer:update(textBus, textBoard))
assert(buffer.readu32(renderer.pixels, 0) == 0xFF000000)
assert(buffer.readu32(renderer.pixels, 8 * 4) == 0xFF00AA00)
print("Text rendering preserved wrapped screen addresses, VGA colors, and blinking")

local responsive = FrameBudget.new(Machine.PIT_HZ)
for frame = 1, 6 do
	local _, time = responsive:beginFrame(1 / 60, true, false)
	if frame == 6 then
		assert(math.abs(time - 0.5 / 60) < 1e-9, "A burst of guest work should reach the CPU ceiling in six frames")
	end
	responsive:endFrame(100, time, 0)
end

local function planarCopy(sourceOffset, destOffset, flags, planes, count)
	local emulator, processor, ram = program(movsb, count, sourceOffset, destOffset, true)
	emulator.bus:mountVgaRom(buffer.create(1))
	local screen = emulator.bus.vga
	buffer.writeu8(screen.sequencer, 2, planes)
	buffer.writeu8(screen.graphics, 5, 1) -- Write mode 1 transfers the latches.
	buffer.writeu8(screen.graphics, 6, 5)
	screen:updateMode()
	screen:render()
	processor:loadSegment(1, 0xA000)
	processor:loadSegment(4, 0xA000)
	processor.flags = flags
	for index = 0, 95 do
		buffer.writeu32(screen.memory, index * 4, 0x10000000 + index * 0x10101)
	end
	return emulator, processor, ram, screen
end

machine, cpu, memory, display = planarCopy(16, 8, 0x202, 15, 64)
local pixelsBefore = buffer.readstring(display.memory, 16 * 4, 64 * 4)
local lastLatch = buffer.readu32(display.memory, 79 * 4)
machine:step()
assert(cpu.ip == 0x502 and machine.board.pit.now == 64)
assert(buffer.readstring(display.memory, 8 * 4, 64 * 4) == pixelsBefore)
assert(display.latches == lastLatch and display:render())

machine, cpu, memory, display = planarCopy(63, 71, 0x602, 15, 64)
pixelsBefore = buffer.readstring(display.memory, 0, 64 * 4)
lastLatch = buffer.readu32(display.memory, 0)
machine:step()
assert(cpu.ip == 0x502 and machine.board.pit.now == 64 and cpu:getRegister(6, true) == 0xFFFF)
assert(buffer.readstring(display.memory, 8 * 4, 64 * 4) == pixelsBefore and display.latches == lastLatch)

machine, cpu, memory, display = planarCopy(0, 1, 0x202, 15, 32)
machine:step()
assert(cpu.ip == 0x500 and machine.board.pit.now == 1)
machine:step()
assert(buffer.readu32(display.memory, 2 * 4) == 0x10000000, "Overlap in the wrong direction must propagate writes")

machine, cpu, memory, display = planarCopy(0, 16, 0x202, 5, 8)
machine:step()
assert(cpu.ip == 0x500 and machine.board.pit.now == 1)
assert(buffer.readu32(display.memory, 16 * 4) == 0x10001000, "Masked planes must retain their original bytes")

machine, cpu, memory, display = planarCopy(16, 8, 0x202, 15, 64)
machine.bus:writePort(0x21, 0xFE)
machine.bus:writePort(0x43, 0x30)
machine.bus:writePort(0x40, 7)
machine.bus:writePort(0x40, 0)
machine:step()
assert(cpu.ip == 0x500 and machine.board.pit.now == 7 and cpu:getRegister(1, true) == 57)
print("Planar scroll batches preserved both directions, latches, plane masks, overlap, and interrupt deadlines")

machine, cpu, memory = program(string.char(0x90), 0, 0, 0, false)
local function descriptor(index, base, limit, access)
	buffer.writeu32(memory, 0x1000 + index * 8, bit32.bor(bit32.lshift(base, 16), limit))
	buffer.writeu32(memory, 0x1004 + index * 8, access * 256 + bit32.extract(base, 16, 8))
end
descriptor(1, 0x3000, 0xFF, 0x92) -- Writable data and stack.
descriptor(2, 0x5000, 0xFF, 0x90) -- Read-only data.
descriptor(3, 0x6000, 0x7F, 0x96) -- Expand down.
cpu.gdt = { base = 0x1000, limit = 0x1F }
cpu.control[0] = 0x11
cpu:loadSegment(4, 8)
cpu:loadSegment(3, 8)
cpu.r[5] = 0xBEEF0080
cpu:push(0xABCD, true)
assert(cpu.r[5] == 0xBEEF007E and buffer.readu16(memory, 0x307E) == 0xABCD)
assert(cpu:pop(true) == 0xABCD and cpu.r[5] == 0xBEEF0080)

local function verifyFault(operation, vector, ...)
	local ok, reason = pcall(operation, cpu, ...)
	assert(not ok and reason.vector == vector)
end
verifyFault(cpu.read, 13, cpu.s[4], 0xFF, true)
verifyFault(cpu.read, 12, cpu.s[3], 0xFF, true)

cpu:loadSegment(4, 16)
buffer.writeu16(memory, 0x5000, 0xFEED)
assert(cpu:read(cpu.s[4], 0, true) == 0xFEED)
verifyFault(cpu.write, 13, cpu.s[4], 0, true, 0)
cpu:loadSegment(4, 24)
cpu:write(cpu.s[4], 0x80, true, 0x1342)
assert(buffer.readu16(memory, 0x6080) == 0x1342)
verifyFault(cpu.write, 13, cpu.s[4], 0x7F, true, 0)

cpu:loadSegment(4, 8)
cpu.control[3] = 0x8000
buffer.writeu32(memory, 0x8000, 0x9003)
buffer.writeu32(memory, 0x900C, 0xA003)
cpu.control[0] = 0x80000011
cpu:write(cpu.s[4], 0x7E, true, 0xCAFE)
assert(cpu:read(cpu.s[4], 0x7E, true) == 0xCAFE and buffer.readu16(memory, 0xA07E) == 0xCAFE)
assert(buffer.readu16(memory, 0x307E) == 0xABCD)
print("16-bit RAM and stack paths preserved segment permissions, stack fault types, upper ESP bits, and paging")

machine, cpu, memory = program(string.char(0x90), 0, 0, 0, false)
local refreshBus, refreshBoard = machine.bus, machine.board
refreshBus:writePort(0x0B, 0x10) -- Channel 0 auto-init.
refreshBus:writePort(0x00, 0)
refreshBus:writePort(0x00, 0x50)
refreshBus:writePort(0x01, 3)
refreshBus:writePort(0x01, 0)
refreshBus:writePort(0x0A, 0)
refreshBus:writePort(0x43, 0x54)
refreshBus:writePort(0x41, 4)
refreshBoard:advance(15)
assert(refreshBus:readPort(0x00) == 3 and refreshBus:readPort(0x00) == 0x50)
assert(refreshBus:readPort(0x08) == 0)
refreshBoard:advance(1)
assert(refreshBus:readPort(0x08) == 1 and refreshBus:readPort(0x08) == 0)
refreshBoard:advance(8)
refreshBus:writePort(0x0A, 4) -- Account for two refreshes before masking.
refreshBoard:advance(40)
refreshBus:writePort(0x0A, 0)
assert(refreshBus:readPort(0x00) == 2 and refreshBus:readPort(0x00) == 0x50)
refreshBoard:advance(4)
refreshBus:writePort(0x43, 0x54)
refreshBus:writePort(0x41, 10)
refreshBoard:advance(9)
assert(refreshBus:readPort(0x08) == 0)
refreshBoard:advance(1)
assert(refreshBus:readPort(0x08) == 1)
print("Deferred DMA refresh preserved port reads, terminal count, masking, and PIT reprogramming")
