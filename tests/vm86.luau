local Bus = require("../src/Bus")
local Cpu386 = require("../src/Cpu386")

local bus = Bus.new(true)
local cpu = Cpu386.new(bus)
local memory = bus.memory

cpu.control[0], cpu.codeMask = 0x11, 0xFFFFFFFF
cpu.s[2] = {
	selector = 0x08,
	base = 0,
	limit = 0xFFFFFFFF,
	big = true,
	readable = true,
	readLimit = 0xFFFFFFFF,
}
cpu.s[3] = {
	selector = 0x10,
	base = 0,
	limit = 0xFFFFFFFF,
	big = true,
	writable = true,
	readLimit = 0xFFFFFFFF,
	writeLimit = 0xFFFFFFFF,
}
cpu:restoreFlags(0x00020002, 32)
assert(not cpu:virtual8086(), "POPF-style flag restoration must not set VM")
cpu.r[5], cpu.ip = 0x8000, 0x1000

local function write32(address, value)
	buffer.writeu32(memory, address, value)
end

write32(0x8000, 0x1234)
write32(0x8004, 0x2000)
write32(0x8008, 0x00020202)
write32(0x800C, 0x76543210)
write32(0x8010, 0x3000)
write32(0x8014, 0x4000)
write32(0x8018, 0x5000)
write32(0x801C, 0x6000)
write32(0x8020, 0x7000)
cpu.r[5] = 0x8000
cpu:iret(32)

assert(cpu:virtual8086() and cpu.cpl == 3, "IRET must enter virtual-8086 mode")
assert(cpu.ip == 0x1234 and cpu.r[5] == 0x76543210)
assert(cpu:selector(2) == 0x2000 and cpu.s[2].base == 0x20000 and cpu.codeMask == 0xFFFF)
assert(cpu:selector(3) == 0x3000 and cpu.s[3].base == 0x30000 and not cpu.s[3].big)
assert(cpu:selector(1) == 0x4000 and cpu:selector(4) == 0x5000)
assert(cpu:selector(5) == 0x6000 and cpu:selector(6) == 0x7000)

buffer.writestring(memory, cpu.s[2].base + cpu.ip, string.char(0xEA, 0x78, 0x56, 0x00, 0x21))
cpu:step()
assert(cpu.ip == 0x5678 and cpu:selector(2) == 0x2100 and cpu.s[2].base == 0x21000)

local ok, failure = pcall(cpu.checkPort, cpu, 0x20, true)
assert(not ok and type(failure) == "table" and failure.vector == 13, "VM86 I/O must trap below IOPL 3")
ok, failure = pcall(cpu.checkInterruptFlag, cpu)
assert(not ok and type(failure) == "table" and failure.vector == 13, "VM86 CLI/STI must trap below IOPL 3")

cpu.control[3] = 0x90000
write32(0x90000, 0x91007)
write32(0x91000 + 0x26 * 4, 0x40007)
buffer.writeu8(memory, 0x40678, 0x90)
cpu.control[0] = 0x80000011
cpu:step()
assert(cpu.ip == 0x5679, "VM86 instruction fetches must pass through paging")
assert(buffer.readu32(memory, 0x90000) == 0x91027)
assert(buffer.readu32(memory, 0x91000 + 0x26 * 4) == 0x40027)
cpu.control[0], cpu.control[3] = 0x11, 0

cpu:loadSegment(2, 0x2100)
cpu.cpl = 3
cpu.flags = bit32.bor(cpu.flags, 0x3000)
cpu.idt = { base = 0x1800, limit = 0x1FF }
cpu.gdt = { base = 0x1000, limit = 0x3F }
write32(0x1008, 0x0000FFFF)
write32(0x100C, 0x00CF9A00)
write32(0x1010, 0x0000FFFF)
write32(0x1014, 0x00CF9200)
cpu.tr = { base = 0x2000, limit = 103, big = true, selector = 0x18, address = 0x101D }
write32(0x2004, 0x9000)
buffer.writeu16(memory, 0x2008, 0x10)
write32(0x1900, 0x00080000)
write32(0x1904, 0x00008E00)
local savedVirtualFlags = cpu.flags
cpu:interrupt(0x20)

assert(not cpu:virtual8086() and cpu.cpl == 0, "Interrupt must enter the protected-mode handler")
assert(cpu:selector(2) == 0x08 and cpu:selector(3) == 0x10 and cpu.ip == 0)
assert(cpu.s[1].unusable and cpu.s[4].unusable and cpu.s[5].unusable and cpu.s[6].unusable)
assert(cpu.r[5] == 0x9000 - 9 * 4, "VM86 interrupt must save the full virtual-mode frame")
assert(buffer.readu32(memory, cpu.r[5] + 8) == savedVirtualFlags)

cpu:iret(32)
assert(cpu:virtual8086() and cpu.cpl == 3, "IRET must restore virtual-8086 mode")
assert(cpu:selector(2) == 0x2100 and cpu.s[2].base == 0x21000)
assert(cpu:selector(3) == 0x3000 and cpu:selector(1) == 0x4000)
assert(cpu:selector(4) == 0x5000 and cpu:selector(5) == 0x6000 and cpu:selector(6) == 0x7000)
assert(cpu.r[5] == 0x76543210 and cpu.ip == 0x5679)

write32(0x1020, 0x30000067)
write32(0x1024, 0x00008900)
write32(0x3020, 0x3456)
write32(0x3024, 0x00020202)
for index = 1, 8 do
	write32(0x3024 + index * 4, index * 0x1111)
end
for index, selector in { 0x4000, 0x2100, 0x3000, 0x5000, 0x6000, 0x7000 } do
	write32(0x3044 + index * 4, selector)
end
write32(0x3060, 0)
cpu:taskSwitch(0x20, "jump")
assert(cpu:virtual8086() and cpu.cpl == 3 and cpu.ip == 0x3456, "Task switches must enter VM86 tasks")
assert(cpu:selector(2) == 0x2100 and cpu.s[2].base == 0x21000 and cpu:selector(3) == 0x3000)
assert(cpu:selector(1) == 0x4000 and cpu:selector(4) == 0x5000)
assert(cpu:selector(5) == 0x6000 and cpu:selector(6) == 0x7000)

print("386 virtual-8086 mode, paging, I/O traps, task switches, and interrupt return passed")
