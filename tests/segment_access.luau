local Bus = require("../src/Bus")
local Cpu386 = require("../src/Cpu386")

local bus = Bus.new(true)
local cpu = Cpu386.new(bus)
local memory = bus.memory
cpu.control[0], cpu.cpl = 0x11, 3
cpu.gdt = { base = 0x1000, limit = 0x3F }

local function descriptor(index, access)
	buffer.writeu32(memory, 0x1000 + index * 8, 0xFFFF)
	buffer.writeu32(memory, 0x1004 + index * 8, bit32.lshift(access, 8))
end

descriptor(1, 0xFA)
descriptor(2, 0xF2)
descriptor(3, 0xF0)
descriptor(4, 0x92)
descriptor(5, 0xFC)
descriptor(6, 0xFE)
cpu:loadSegment(2, 0x0B)

local function verify(opcode, selector, allowed)
	cpu.ip, cpu.flags = 0x2000, 0x8D7
	cpu:setRegister(0, true, selector)
	buffer.writestring(memory, 0x2000, string.char(0x0F, 0, opcode))
	cpu:step()
	assert(cpu.flags == (if allowed then 0x8D7 else 0x897))
end

verify(0xE0, 0x13, true)
verify(0xE8, 0x13, true)
verify(0xE0, 0x1B, true)
verify(0xE8, 0x1B, false)
verify(0xE0, 0x23, false)
verify(0xE0, 0x2B, false)
verify(0xE0, 0x33, true)
verify(0xE8, 0x33, false)
verify(0xE0, 0x17, false) -- TI set, with no LDT loaded
verify(0xE0, 0, false)
verify(0xE0, 0x83, false)
print("386 VERR and VERW report segment type, privilege, and invalid selectors")

local faultCpu = Cpu386.new(bus)
faultCpu:loadSegment(2, 0)
faultCpu:loadSegment(3, 0)
faultCpu.ip, faultCpu.r[5] = 0x2000, 0x3000
buffer.writeu16(memory, 6 * 4, 0x4000)
buffer.writeu16(memory, 6 * 4 + 2, 0)
buffer.writestring(memory, 0x2000, string.char(0x0F, 0xFF))
faultCpu:step()
assert(faultCpu.ip == 0x4000 and buffer.readu16(memory, 0x2FFA) == 0x2000)
faultCpu.ip, faultCpu.r[5] = 0x2000, 0x3000
buffer.writestring(memory, 0x2000, string.char(0x0F, 0xA6))
faultCpu:step()
assert(faultCpu.ip == 0x4000 and buffer.readu16(memory, 0x2FFA) == 0x2000)
for _, instruction in
	{
		string.char(0x8E, 0xF0),
		string.char(0x8E, 0x08),
	}
do
	faultCpu.ip, faultCpu.r[5] = 0x2000, 0x3000
	buffer.writestring(memory, 0x2000, instruction)
	faultCpu:step()
	assert(faultCpu.ip == 0x4000 and buffer.readu16(memory, 0x2FFA) == 0x2000)
end
print("Reserved opcodes and invalid segment-register encodings deliver restartable invalid-opcode faults")

local arplCpu = Cpu386.new(bus)
arplCpu:loadSegment(2, 0)
arplCpu.control[0], arplCpu.ip, arplCpu.flags = 0x11, 0x5000, 0x897
arplCpu:setRegister(0, 32, 0xDEAD1230)
arplCpu:setRegister(1, 16, 0x0003)
buffer.writestring(memory, 0x5000, string.char(0x66, 0x63, 0xC8))
arplCpu:step()
assert(arplCpu:getRegister(0, 32) == 0xDEAD1233 and arplCpu.flags == 0x8D7)

arplCpu.ip, arplCpu.flags = 0x5000, 0x8D7
arplCpu:setRegister(0, 16, 0x1233)
arplCpu:setRegister(1, 16, 0x0001)
buffer.writestring(memory, 0x5000, string.char(0x63, 0xC8))
arplCpu:step()
assert(arplCpu:getRegister(0, 16) == 0x1233 and arplCpu.flags == 0x897)
print("386 ARPL adjusts a selector RPL and updates only ZF")
