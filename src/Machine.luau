local Bus = if script then require(script.Parent.Bus) else require("./Bus")
local Cpu8088 = if script then require(script.Parent.Cpu8088) else require("./Cpu8088")
local Cpu386 = if script then require(script.Parent.Cpu386) else require("./Cpu386")
local XtBoard = if script then require(script.Parent.XtBoard) else require("./XtBoard")

-- The XT derives the CPU and PIT clocks from the same crystal.
local Machine = {
	CPU_HZ = 14_318_180 / 3,
	PIT_HZ = 14_318_180 / 12,
	CPU_386_HZ = 16_000_000,
}
Machine.__index = Machine

local function newMachine(rom, disk, diskRom, hardDisk, atRom, vgaRom, seaBios, secondHardDisk)
	local at = atRom ~= nil or seaBios == true
	local bus = Bus.new(at)
	if seaBios then
		bus:mountSeaBios(rom, vgaRom, hardDisk)
	else
		bus:mountSystemRom(rom)
	end
	if vgaRom and not seaBios then
		bus:mountVgaRom(vgaRom)
	end
	if diskRom and hardDisk then
		bus:mountDiskRom(diskRom)
	end
	if atRom then
		bus:mountAtRom(atRom)
	end
	return setmetatable({
		atRom = atRom,
		vgaRom = vgaRom,
		rom = rom,
		diskRom = diskRom,
		bus = bus,
		board = XtBoard.new(bus, disk, hardDisk, Machine.PIT_HZ, secondHardDisk),
		cpu = if at then Cpu386.new(bus) else Cpu8088.new(bus),
	}, Machine)
end

function Machine.new(rom, disk, diskRom, hardDisk, atRom, vgaRom)
	return newMachine(rom, disk, diskRom, hardDisk, atRom, vgaRom, false)
end

function Machine.newSeaBios(rom, vgaRom, disk, hardDisk, secondHardDisk)
	assert(not secondHardDisk or hardDisk, "A second IDE disk requires a primary disk")
	return newMachine(rom, disk, nil, hardDisk, nil, vgaRom, true, secondHardDisk)
end

function Machine:restart()
	local hardDisk = self.board.hardDisk
	local secondHardDisk = self.board.secondHardDisk
	return newMachine(
		self.rom,
		self.board.floppy.image,
		self.diskRom,
		hardDisk and hardDisk.image,
		self.atRom,
		self.vgaRom,
		self.bus.firmware ~= nil,
		secondHardDisk and secondHardDisk.image
	)
end

local function step(self, haltLimit, execute)
	local cpu, board = self.cpu, self.board
	-- With neither PIC holding a request there is no interrupt to deliver.
	local slave = board.slavePic
	if (board.pic.pending ~= 0 or (slave and slave.pending ~= 0)) and cpu:canInterrupt() then
		local vector = board:acknowledgeInterrupt()
		if vector ~= nil then
			cpu:interrupt(vector)
		end
	end
	if cpu.halted and haltLimit then
		local clocks = if cpu:canInterrupt() then math.min(haltLimit, board:clocksUntilIrq(true)) else haltLimit
		board:advance(clocks)
		return
	end
	local flags = bit32.band(cpu.flags, 0x300)
	-- The 386 RAM fast path can also batch with interrupts enabled,
	-- stopping at the next device event.
	local repeatLimit = if flags == 0 or (flags == 0x200 and self.bus.at and not cpu.interruptShadow) then 64 else 1
	local iterations = execute(cpu, repeatLimit) or 1
	local bus = self.bus
	local pc = bus.pc
	if pc then
		if pc.resetRequested then
			local restarted = self:restart()
			self.bus, self.board, self.cpu = restarted.bus, restarted.board, restarted.cpu
			return true
		end
		if pc.awaitingDiskBoot and cpu.s[2].base + cpu.ip == 0x7C00 then
			pc:diskBoot(cpu, bus.memory)
		end
	end
	-- The PIT is driven by approximate guest time. HLT leaves the timers running.
	local ticks = self.bus.at and 1 or 3
	board:advance(cpu.halted and 32 or ticks * iterations)
end

function Machine:step(haltLimit)
	return step(self, haltLimit, self.cpu.step)
end

local function runSlice(self, target, deadline, execute)
	local pit = self.board.pit
	while pit.now < target and os.clock() < deadline do
		for _ = 1, 64 do
			if pit.now >= target then
				break
			end
			if step(self, target - pit.now, execute) then
				return true
			end
		end
	end
end

function Machine:runSlice(target, deadline)
	local cpu, board = self.cpu, self.board
	if not self.bus.at then
		return runSlice(self, target, deadline, cpu.step)
	end

	while true do
		local ok, result = pcall(runSlice, self, target, deadline, cpu.stepInSlice)
		if ok then
			return result
		end
		local code = cpu.faultCode
		cpu.faultCode = nil
		if not code then
			error(result, 0)
		end
		cpu:finishFault(result, cpu.faultIp, code)
		board:advance(if cpu.halted then 32 else 1)
	end
end

return Machine
