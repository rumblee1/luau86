local Machine = require("../src/Machine")
local decode = require("../src/MediaDecode")

local firmwareIndex = require("../src/media/SeaBios/Index")
local firmware = buffer.create(firmwareIndex.size)
for _, part in firmwareIndex.parts do
	decode(require("../src/media/SeaBios/" .. part[2]), firmware, part[1])
end
local vga = decode(require("../src/media/SeaVgaBios"))
local disk = buffer.create(256 * 1024)
-- INT 11h; MOV BX, AX; CLI; HLT
buffer.writestring(disk, 0, string.char(0xCD, 0x11, 0x89, 0xC3, 0xFA, 0xF4))
buffer.writeu16(disk, 510, 0xAA55)
local machine = Machine.newSeaBios(firmware, vga, nil, disk)
for clock = 500000, 16000000, 500000 do
	machine:runSlice(clock, math.huge)
	if machine.cpu.halted and machine.cpu.ip == 0x7C06 then
		break
	end
end
local cpu = machine.cpu
assert(cpu.halted and cpu.ip == 0x7C06, "The SeaBIOS boot probe must reach HLT")
local flags = cpu:getRegister(3, true)
assert(
	bit32.band(flags, 2) == 0 and bit32.band(flags, 0x20) ~= 0,
	"INT 11h must advertise a PC without a math coprocessor"
)
assert(flags == buffer.readu16(machine.bus.memory, 0x410))
print(string.format("Stock SeaBIOS disk boot reported equipment %04X with the math coprocessor bit clear", flags))
