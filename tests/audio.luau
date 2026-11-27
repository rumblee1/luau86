local Machine = require("../src/Machine")
local decode = require("../src/MediaDecode")
local SoundBlaster = require("../src/SoundBlaster")

local media = "../src/media/"
local machine = Machine.new(
	decode(require(media .. "Bios")),
	decode(require(media .. "Disk")),
	nil,
	nil,
	decode(require(media .. "AtBios"))
)
local board, bus = machine.board, machine.bus
local audio = board:enableAudio()

bus:writePort(0x43, 0xB6)
bus:writePort(0x42, 0xA9)
bus:writePort(0x42, 0x04) -- ~1 kHz
bus:writePort(0x61, 3)
assert(math.abs(board:pcSpeakerFrequency() - 1000) < 1)
assert(bit32.band(bus:readPort(0x61), 0x20) ~= 0)
board:advance(700)
assert(bit32.band(bus:readPort(0x61), 0x20) == 0)
board:advance(math.floor(Machine.PIT_HZ / 20) - 700)
local samples, count = audio:take()
local positive, negative = false, false
assert(count >= 1190 and count <= 1210)
for index = 0, count - 1 do
	local sample = buffer.readf32(samples, index * 4)
	positive = positive or sample > 0.1
	negative = negative or sample < -0.1
end
assert(positive and negative)
bus:writePort(0x61, 0)
assert(board:pcSpeakerFrequency() == nil)
board:advance(math.floor(Machine.PIT_HZ / 10))
samples, count = audio:take()
assert(math.abs(buffer.readf32(samples, (count - 1) * 4)) < 0.001)
print("PC speaker followed PIT channel 2 and port 61h")

local function dsp(...)
	for _, value in { ... } do
		bus:writePort(0x22C, value)
	end
end

local function resetDsp()
	bus:writePort(0x226, 1)
	bus:writePort(0x226, 0)
	assert(bus:readPort(0x22E) == 0x80 and bus:readPort(0x22A) == 0xAA)
end

local function dma(mode, count)
	bus:writePort(0x0A, 5)
	bus:writePort(0x0C, 0)
	bus:writePort(0x02, 0x00)
	bus:writePort(0x02, 0x30)
	bus:writePort(0x83, 0)
	bus:writePort(0x03, count - 1)
	bus:writePort(0x03, 0)
	bus:writePort(0x0B, mode)
	bus:writePort(0x0A, 1)
end

local function ack()
	assert(board.pic.pending == bit32.lshift(1, SoundBlaster.IRQ))
	assert(board:acknowledgeInterrupt() == 8 + SoundBlaster.IRQ)
	bus:readPort(0x22E)
	bus:writePort(0x20, 0x20)
end

resetDsp()
dsp(0xE1)
assert(bus:readPort(0x22A) == 2 and bus:readPort(0x22A) == 1)
for index, value in { 0, 32, 224, 255 } do
	bus:write8(0x3000 + index - 1, value)
end
dma(0x49, 4)
bus:writePort(0x21, 0xDF)
dsp(0xD1, 0x40, 131, 0x14, 3, 0)
assert(board:clocksUntilIrq() == 150 and board:clocksUntilIrq(true) == 597)
board:advance(596)
assert(board.pic.pending == 0)
board:advance(1)
ack()
assert(bus:readPort(8) == 2 and board.dma.channels[1].count == 0xFFFF)
board:advance(200)
samples, count = audio:take()
positive, negative = false, false
for index = 0, count - 1 do
	local sample = buffer.readf32(samples, index * 4)
	positive = positive or sample > 0.5
	negative = negative or sample < -0.5
end
assert(positive and negative and audio.dac == 0)

resetDsp()
dma(0x59, 4)
dsp(0xD1, 0x40, 131, 0x48, 1, 0, 0x1C)
board:advance(299)
ack()
assert(board.dma.channels[1].address == 0x3002)
board:advance(299)
ack()
assert(board.dma.channels[1].address == 0x3000 and bus:readPort(8) == 2)
dsp(0xDA)
board:advance(299)
ack()
board:advance(1000)
assert(board.pic.pending == 0 and audio.dac == 0)
print("Sound Blaster DSP detected correctly and played single-cycle and auto-init DMA with IRQ 5")

-- A sleeping CPU can catch up to the next event without swallowing the IRQ.
local cpu = machine.cpu
cpu:loadSegment(2, 0)
cpu.ip = 0x400
cpu:setRegister(4, true, 0x7000)
cpu.flags = 0x202
cpu.halted = true
buffer.writeu16(bus.memory, (8 + SoundBlaster.IRQ) * 4, 0x500)
buffer.writeu8(bus.memory, 0x500, 0x90)
resetDsp()
dma(0x49, 4)
dsp(0xD1, 0x40, 131, 0x14, 3, 0)
local before = board.pit.now
machine:step(300)
assert(board.pit.now == before + 300 and cpu.halted and board.pic.pending == 0)
machine:step(400)
assert(board.pit.now == before + 597 and cpu.halted and board.pic.pending == 32)
machine:step(400)
assert(not cpu.halted and cpu.ip == 0x501)
print("A sleeping CPU advanced to the next DMA interrupt while preserving the callback deadline")

local GuestAudio = require("../src/GuestAudio")
local timer = { now = 0 }
local waveform = GuestAudio.new(timer, 240000)
waveform:setDac(0.75, 5)
waveform:setDac(-0.5, 40)
waveform:setDac(0, 65)
timer.now = 80
samples, count = waveform:take()
assert(count == 8)
for index, level in { 0, 0.75, 0.75, 0.75, -0.5, -0.5, -0.5, 0 } do
	assert(buffer.readf32(samples, (index - 1) * 4) == level, "DMA must hold each level until the next write")
end
print("Guest waveform kept its sample timing through DAC changes")
