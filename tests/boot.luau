local scanCodes = require("../src/Keyboard")
local Machine = require("../src/Machine")
local readScreen = require("../src/TextScreen")
local CgaText = require("../src/CgaText")
local decode = require("../src/MediaDecode")
local rom = decode(require("../src/media/Bios"))

local function runUntil(machine, condition, limit)
	for _ = 1, limit do
		for _ = 1, 1024 do
			machine:step()
		end
		local text = readScreen(machine.bus, machine.board)
		if condition(text) then
			return text
		end
		assert(not machine.cpu.halted or machine.cpu:canInterrupt(), "Guest halted early\n" .. text)
	end
	error("Guest did not reach its milestone\n" .. readScreen(machine.bus, machine.board))
end

local testMachine = Machine.new(rom, decode(require("../src/media/BootTest")))
local bootScreen = runUntil(testMachine, function(text)
	return text:find("BOOT OK", 1, true) ~= nil
end, 2400)
assert(bootScreen:find("GLaBIOS", 1, true) and bootScreen:find("640 KB OK", 1, true), "Expected real GLaBIOS POST")
assert(bootScreen:match("CPU%s+%[ 8088 %]"), "Expected 8088 identification in the XT profile")
assert(not bootScreen:find("POST Error", 1, true), "POST reported an error")
print("GLaBIOS POST and hardware floppy boot passed")

local template = decode(require("../src/media/Disk"))
local originalImage = buffer.tostring(template)
local machine = Machine.new(rom, template)
local prompt = "A:\\>"
local startup = runUntil(machine, function(text)
	return text:find(prompt, 1, true) ~= nil
end, 6000)
assert(startup:find("FreeDOS kernel", 1, true), "Expected FreeDOS kernel output")

local commandKeys = { [" "] = "Space", ["."] = "Period", ["\r"] = "Return" }
local function typeCommand(command)
	for key in (command .. "\r"):gmatch(".") do
		local scan = assert(scanCodes[commandKeys[key] or key:upper()])
		machine.board:queueScanCode(scan)
		machine.board:queueScanCode(scan + 0x80)
		-- Give DOS time to consume each keystroke, as it would during typing.
		for _ = 1, 8192 do
			machine:step()
		end
	end
end

local function atPrompt(text)
	return text:match("A:\\>%s*$") ~= nil
end

typeCommand("dir")
runUntil(machine, function(text)
	return text:find("HELLO%s+COM") ~= nil and atPrompt(text)
end, 1500)
print("FreeDOS accepted I in DIR and listed the floppy")

typeCommand("hello")
local output = runUntil(machine, function(text)
	return text:find("Hello from Luau86!", 1, true) ~= nil and atPrompt(text)
end, 1500)
assert(output:find("A:\\>hello", 1, true), "FreeCOM should echo the keyboard command")
print("FreeDOS accepted HELLO through the XT keyboard and returned to A:\\>")

typeCommand("copy hello.com test.com")
runUntil(machine, function(text)
	return text:find("hello.com =>> test.com", 1, true) ~= nil and atPrompt(text)
end, 1500)

local function runCopiedProgram()
	typeCommand("test")
	runUntil(machine, function(text)
		return text:match("A:\\>test *\nHello from Luau86!") ~= nil and atPrompt(text)
	end, 1500)
end

runCopiedProgram()
print("FreeDOS copied HELLO.COM to TEST.COM and ran the copy")

local modifiedImage = buffer.tostring(machine.board.floppy.image)
assert(modifiedImage ~= originalImage, "COPY must change the mounted disk image")
assert(buffer.tostring(template) == originalImage, "COPY must leave the boot template unchanged")
local restarted = machine:restart()
assert(restarted.board.floppy.image ~= machine.board.floppy.image)
assert(buffer.tostring(restarted.board.floppy.image) == modifiedImage, "Restart must preserve guest files")
local independent = Machine.new(rom, template)
assert(buffer.tostring(independent.board.floppy.image) == originalImage, "A new session must start from the template")
print("Floppy contents persist across Restart and stay isolated between sessions")

machine = restarted
runUntil(machine, atPrompt, 6000)
runCopiedProgram()
print("TEST.COM runs from disk after a fresh FreeDOS boot")

local renderer = CgaText.new(decode(require("../src/media/Font")))
local y, height, pixels = renderer:update(machine.bus, machine.board)
assert(y == 0 and height == CgaText.HEIGHT and buffer.len(pixels) == 640 * 200 * 4)
assert(renderer:update(machine.bus, machine.board) == nil, "An unchanged frame should have no update")
local first = buffer.readu32(pixels, 0)
local hasInk = false
for offset = 4, buffer.len(pixels) - 4, 4 do
	if buffer.readu32(pixels, offset) ~= first then
		hasInk = true
		break
	end
end
assert(hasInk, "The CGA renderer should rasterize guest text")

local bus, board = machine.bus, machine.board
board:write(0x3D4, 12)
board:write(0x3D5, 0)
board:write(0x3D4, 13)
board:write(0x3D5, 0)
board:write(0x3D4, 10)
board:write(0x3D5, 0x20) -- Disable the cursor for the pixel check.
board:write(0x3D8, 0x09)
renderer:update(bus, board)
local testCell = 4 * 80 + 2
bus:write8(0xB8000 + testCell * 2, 0x20)
bus:write8(0xB8001 + testCell * 2, 0x41)
y, height, pixels = renderer:update(bus, board)
assert(y == 32 and height == 8, "A cell write should only upload its dirty row")
assert(
	buffer.readu32(pixels, 16 * 4) == 0xFF0000AA,
	"CGA palette and byte ordering should yield an opaque red background"
)
print("CGA framebuffer and dirty-row updates passed")
