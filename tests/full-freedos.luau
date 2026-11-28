local Machine = require("../src/Machine")
local readScreen = require("../src/TextScreen")
local decode = require("../src/MediaDecode")
local scanCodes = require("../src/Keyboard")

local index = require("../src/media/freedos_combined/Index")
local disk = buffer.create(index.size)
for _, part in index.parts do
	decode(require("../src/media/freedos_combined/" .. part[2]), disk, part[1])
end

local machine = Machine.new(
	decode(require("../src/media/Bios")),
	decode(require("../src/media/Disk")),
	decode(require("../src/media/DiskRom")),
	disk
)

local function runUntil(condition, steps)
	for _ = 1, steps do
		for _ = 1, 1024 do
			machine:step()
		end
		local text = readScreen(machine.bus, machine.board)
		if condition(text) then
			return
		end
		assert(not machine.cpu.halted or machine.cpu:canInterrupt(), "Guest halted early\n" .. text)
	end
	error("Guest did not reach its milestone\n" .. readScreen(machine.bus, machine.board))
end

local function atPrompt(text)
	return text:match("C:\\>%s*$") ~= nil
end

local special =
	{ [" "] = "Space", ["."] = "Period", ["/"] = "Slash", [":"] = "Semicolon", ["\\"] = "BackSlash", ["\r"] = "Return" }
local function typeCommand(command)
	for character in (command .. "\r"):gmatch(".") do
		local scan = assert(scanCodes[special[character] or character:upper()])
		if character == ":" then
			machine.board:queueScanCode(scanCodes.LeftShift)
		end
		machine.board:queueScanCode(scan)
		machine.board:queueScanCode(scan + 0x80)
		if character == ":" then
			machine.board:queueScanCode(scanCodes.LeftShift + 0x80)
		end
		for _ = 1, 8192 do
			machine:step()
		end
	end
end

runUntil(atPrompt, 9000)
print("FreeDOS mounted the full installation as C:")
typeCommand("vga")
runUntil(function(text)
	return text:find("VGA Library", 1, true) ~= nil and atPrompt(text)
end, 3000)
print("The combined image includes the VGA library and apps")
typeCommand("dir fdos\\bin\\mem.exe /b")
runUntil(function(text)
	return text:lower():find("mem.exe", 1, true) ~= nil and atPrompt(text)
end, 3000)
print("FreeDOS can read the bundled program directory")

typeCommand("dir a:\\hello.com /b")
runUntil(function(text)
	return text:find("HELLO.COM", 1, true) ~= nil and atPrompt(text)
end, 2000)
print("The original floppy remains accessible as A:")

typeCommand("mem")
runUntil(function(text)
	return text:find("Conventional", 1, true) ~= nil and atPrompt(text)
end, 3500)
print("The installed MEM command ran from the C: PATH")

typeCommand("copy fdos\\bin\\mem.exe memcopy.exe")
runUntil(function(text)
	return text:lower():find("=>> memcopy.exe", 1, true) ~= nil and atPrompt(text)
end, 6500)
typeCommand("memcopy")
runUntil(function(text)
	return text:match("C:\\>memcopy[%s%S]*Conventional") ~= nil and atPrompt(text)
end, 3500)
assert(buffer.tostring(disk) ~= buffer.tostring(machine.board.hardDisk.image))
print("The FAT16 hard disk can write and execute a bundled program copy")
