local Machine = require("../src/Machine")

local primary = buffer.create(256 * 1024)
local secondary = buffer.create(256 * 1024)
buffer.writeu32(primary, 0, 0x11112222)
buffer.writeu32(secondary, 0, 0x33334444)

local machine = Machine.newSeaBios(buffer.create(256 * 1024), buffer.create(512), nil, primary, secondary)

local function command(bus, drive, operation, sectors)
	bus:writePort(0x1F6, 0xE0 + drive * 16)
	bus:writePort(0x1F2, sectors or 1)
	bus:writePort(0x1F3, 0)
	bus:writePort(0x1F4, 0)
	bus:writePort(0x1F5, 0)
	bus:writePort(0x1F7, operation)
end

command(machine.bus, 0, 0x20)
assert(machine.bus:readIo(0x1F0, 4) == 0x11112222, "primary LBA read")
command(machine.bus, 1, 0x20)
assert(machine.bus:readIo(0x1F0, 4) == 0x33334444, "secondary LBA read")
command(machine.bus, 1, 0x30)
machine.bus:writeIo(0x1F0, 0x55556666, 4)
for _ = 2, 128 do
	machine.bus:writeIo(0x1F0, 0, 4)
end

machine = machine:restart()
command(machine.bus, 0, 0x20)
assert(machine.bus:readIo(0x1F0, 4) == 0x11112222, "secondary write did not modify the primary disk")
command(machine.bus, 1, 0x20)
assert(machine.bus:readIo(0x1F0, 4) == 0x55556666, "secondary write survived restart")

local oneDisk = Machine.newSeaBios(buffer.create(256 * 1024), buffer.create(512), nil, primary)
command(oneDisk.bus, 1, 0xEC)
assert(oneDisk.bus:readPort(0x1F7) == 0, "an unpopulated secondary slot reads as absent")
print("Primary and secondary IDE reads, writes, and restart passed")

local bus, cpu, board = machine.bus, machine.cpu, machine.board
local function prepareRead(code, count, destination)
	cpu:loadSegment(2, 0)
	cpu.ip, cpu.flags, cpu.halted = 0x500, 2, false
	cpu:setRegister(1, true, count)
	cpu:setRegister(2, true, 0x1F0)
	cpu:setRegister(7, true, destination)
	buffer.writestring(bus.memory, 0x500, code)
end

local expected = string.rep(string.char(1, 2, 3, 4), 255) .. "last"
buffer.writestring(board.secondHardDisk.image, 0, expected)
command(bus, 1, 0x20, 2)
board.slavePic.pending = 0 -- Ignore the initial data-ready IRQ.
prepareRead(string.char(0xF3, 0x6D), 512, 0x2000)
for _ = 1, 3 do
	machine:step()
end
assert(board.pit.now == 192 and cpu:getRegister(1, true) == 320 and cpu.ip == 0x500)
assert(board.slavePic.pending == 0, "The next IRQ belongs at the sector boundary")
machine:step()
assert(board.slavePic.pending == 64 and board.pit.now == 256, "Reading the next sector should signal IRQ 14")
for _ = 1, 4 do
	machine:step()
end
assert(cpu:getRegister(1, true) == 0 and cpu.ip == 0x502 and board.pit.now == 512)
assert(bus:readPort(0x1F7) == 0x50 and buffer.readstring(bus.memory, 0x2000, 1024) == expected)
assert(board.secondHardDisk.sectorsRead == 2 and board.hardDisk.sectorsRead == 0)

command(bus, 1, 0x20)
prepareRead(string.char(0x66, 0xF3, 0x6D), 128, 0xFFFC)
machine:step()
assert(cpu:getRegister(1, true) == 127 and cpu:getRegister(7, true) == 0)
assert(buffer.readstring(bus.memory, 0xFFFC, 4) == expected:sub(1, 4))
while cpu.ip == 0x500 do
	machine:step()
end
assert(cpu:getRegister(7, true) == 508 and buffer.readstring(bus.memory, 0, 508) == expected:sub(5, 512))
print("REP INSW and INSD preserved sector IRQs, drive selection, guest clock accounting, and address wrap")

command(bus, 1, 0x20)
prepareRead(string.char(0xF3, 0x6D), 32, 0x3000)
cpu.flags = 0x202
bus:writePort(0x21, 0xFE)
bus:writePort(0x43, 0x30)
bus:writePort(0x40, 7)
bus:writePort(0x40, 0)
local before = board.pit.now
machine:step()
assert(board.pit.now == before + 7 and cpu:getRegister(1, true) == 25 and board.pic.pending == 1)
assert(buffer.readstring(bus.memory, 0x3000, 14) == expected:sub(1, 14))
print("IDE read batches stop at the next device deadline")
