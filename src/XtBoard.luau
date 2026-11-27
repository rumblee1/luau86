local AtaDisk = if script then require(script.Parent.AtaDisk) else require("./AtaDisk")
local HardDisk = if script then require(script.Parent.HardDisk) else require("./HardDisk")
local Dma8237 = if script then require(script.Parent.Dma8237) else require("./Dma8237")
local Floppy765 = if script then require(script.Parent.Floppy765) else require("./Floppy765")
local SerialMouse = if script then require(script.Parent.SerialMouse) else require("./SerialMouse")
local Pic8259 = if script then require(script.Parent.Pic8259) else require("./Pic8259")
local Pit8253 = if script then require(script.Parent.Pit8253) else require("./Pit8253")

local SoundBlaster = if script then require(script.Parent.SoundBlaster) else require("./SoundBlaster")
local GuestAudio = if script then require(script.Parent.GuestAudio) else require("./GuestAudio")

local band = bit32.band
local KEYBOARD_BYTE_CLOCKS = 1100 -- Serial transmission time in PIT clocks.
local BOARD_SWITCHES = 0x2D -- Four RAM banks, 80-column CGA, one floppy drive.

local Board = {}
Board.__index = Board

function Board.new(bus, disk, hardDisk, clockRate, secondHardDisk)
	local pic = Pic8259.new()
	local slavePic = bus.at and Pic8259.new()
	local dma = Dma8237.new()
	local function ideInterrupt()
		slavePic:request(6)
	end
	local board = setmetatable({
		pic = pic,
		serialMouse = bus.vga and SerialMouse.new(function()
			pic:request(4)
		end),
		bus = bus,
		slavePic = slavePic,
		-- The VGA AT starts with an 8042 output buffer. A guest can read
		-- subsequent scan codes without pulsing the XT latch on port 61h.
		atKeyboard = bus.vga ~= nil,
		kbcConfig = 0x41,
		kbcCommand = 0,
		kbcResponse = nil,
		rtcStart = bus.at and os.time(),
		cmos = bus.at and buffer.create(128),
		cmosIndex = 0,
		pit = Pit8253.new(function()
			pic:request(0)
		end),
		dma = dma,
		clockRate = clockRate,
		soundBlaster = bus.at and SoundBlaster.new(bus, dma, clockRate, function()
			pic:request(SoundBlaster.IRQ)
		end),
		hardDisk = hardDisk and (if bus.pc then AtaDisk.new(hardDisk, ideInterrupt) else HardDisk.new(bus, hardDisk)),
		secondHardDisk = secondHardDisk and AtaDisk.new(secondHardDisk, ideInterrupt),
		ideDevice = 0,
		floppy = Floppy765.new(bus, dma, disk, function(line)
			pic:request(line)
		end),
		ppiB = 0,
		keyboard = {},
		keyboardHeld = false,
		keyboardReadyAt = 0,
		scanCode = nil,
		crtc = buffer.create(32),
		crtcIndex = 0,
		cgaMode = 0,
		cgaColor = 0,
		videoVersion = 0,
	}, Board)
	if board.cmos then
		local conventional, extended = bus:ramKiB()
		if bus.firmware then
			buffer.writeu8(board.cmos, 0x10, disk and 0x10 or 0)
			-- SeaBIOS reads the boot order from the lowest nibble first.
			local bootOrder = if hardDisk then (if disk then 0x12 else 2) else 1
			buffer.writeu8(board.cmos, 0x3D, bootOrder)
		end
		buffer.writeu16(board.cmos, 0x15, conventional)
		buffer.writeu16(board.cmos, 0x17, extended)
		buffer.writeu16(board.cmos, 0x30, extended)
	end
	bus.io = board
	return board
end

function Board:pcSpeakerFrequency()
	local timer = self.pit.channels[2]
	if band(self.ppiB, 3) == 3 and timer.running and (timer.mode == 2 or timer.mode == 3) then
		return self.clockRate / timer.reload
	end
	return nil
end

function Board:enableAudio()
	local audio = GuestAudio.new(self.pit, self.clockRate)
	self.audio = audio
	audio.speaker = band(self.ppiB, 2) ~= 0
	if self.soundBlaster then
		self.soundBlaster.audio = audio
		self.soundBlaster:setLevel(self.soundBlaster.level, self.pit.now)
	end
	return audio
end

function Board:disableAudio()
	self.audio = nil
	if self.soundBlaster then
		self.soundBlaster.audio = nil
	end
end

-- Refresh only affects DMA channel 0 registers. Synchronize before a
-- guest can observe them or change the DMA or PIT configuration.
function Board:syncDmaRefresh()
	local periods = self.pit:takeRefresh()
	if periods > 0 then
		self.dma:refresh(periods)
	end
end

function Board:advance(clocks)
	local pit = self.pit
	local now = pit.now + clocks
	pit.now = now
	if now >= pit.timer.next then
		pit:raiseTimerIrq()
	end
	local soundBlaster = self.soundBlaster
	if soundBlaster and now >= soundBlaster.nextAt then
		soundBlaster:advance(now)
	end
	local serialMouse = self.serialMouse
	if serialMouse and now >= serialMouse.deliverAt then
		serialMouse:advance(now)
	end
	if #self.keyboard > 0 and now >= self.keyboardReadyAt then
		self:pumpKeyboard()
	end
end

-- A batch may finish on a device boundary. The following CPU step can
-- then acknowledge the interrupt before it resumes the string instruction.
function Board:clocksUntilIrq(halted)
	if self.pic:ready() or (self.slavePic and self.slavePic:ready()) then
		return 1
	end
	local now = self.pit.now
	local clocks = self.pit:clocksUntilIrq()
	if self.soundBlaster then
		local dsp = self.soundBlaster
		local ticks = dsp.nextAt - now
		if halted then
			-- Guest RAM is stable while the CPU sleeps. Process DMA samples in
			-- advance() and wake no later than the end-of-block interrupt.
			ticks += math.max(0, dsp.remaining - 1) * dsp.period
		end
		clocks = math.min(clocks, ticks)
	end
	if self.serialMouse then
		clocks = math.min(clocks, self.serialMouse.deliverAt - now)
	end
	if self.scanCode == nil and #self.keyboard > 0 then
		clocks = math.min(clocks, self.keyboardReadyAt - now)
	end
	return math.max(1, math.ceil(clocks))
end

function Board:acknowledgeInterrupt()
	local pic, slave = self.pic, self.slavePic
	local cascade = slave and slave.pending ~= 0 and slave:ready() ~= nil
	if cascade then
		pic:request(2)
	elseif pic.pending == 0 then
		return nil
	end
	local vector = pic:acknowledge()
	if cascade and vector == pic.vectorBase + 2 then
		return slave:acknowledge()
	end
	return vector
end

function Board:writeKeyboardCommand(value)
	self.atKeyboard = true
	self:pumpKeyboard()
	if value == 0x20 then
		self.kbcResponse = self.kbcConfig
	elseif value == 0xAA then
		self.kbcResponse = 0x55
	elseif value == 0xAB then
		self.kbcResponse = 0
	elseif value == 0xD0 then
		self.kbcResponse = self.bus.a20 and 3 or 1
	elseif value == 0xAD then
		self.kbcConfig = bit32.bor(self.kbcConfig, 0x10)
	elseif value == 0xAE then
		self.kbcConfig = band(self.kbcConfig, 0xEF)
	elseif value == 0xA7 then
		self.kbcConfig = bit32.bor(self.kbcConfig, 0x20)
	elseif value == 0xA8 then
		self.kbcConfig = band(self.kbcConfig, 0xDF)
	end
	self.kbcCommand = value
end

function Board:writeKeyboardData(value)
	if self.kbcCommand == 0xD1 then
		self.bus.a20 = band(value, 2) ~= 0
	elseif self.kbcCommand == 0x60 then
		self.kbcConfig = value
	else
		self.kbcResponse = 0xFA
		if value == 0xFF then -- Keyboard reset: ACK followed by self-test passed.
			self.kbcNextResponse = 0xAA
		end
		if band(self.kbcConfig, 1) ~= 0 then
			self.pic:request(1)
		end
	end
	self.kbcCommand = 0
end

function Board:pumpKeyboard()
	if
		self.scanCode == nil
		and #self.keyboard > 0
		and (self.atKeyboard or band(self.ppiB, 0xC0) == 0x40)
		and self.pit.now >= self.keyboardReadyAt
	then
		self.scanCode = table.remove(self.keyboard, 1)
		if not self.atKeyboard or band(self.kbcConfig, 1) ~= 0 then
			self.pic:request(1)
		end
	end
end

function Board:queueScanCode(value)
	-- Bound the host queue if the guest stops acknowledging keys.
	if #self.keyboard < 256 then
		table.insert(self.keyboard, value)
		self:pumpKeyboard()
	end
end

function Board:writePpi(value)
	local old = self.ppiB
	if self.audio and band(old, 3) ~= band(value, 3) then
		self.audio:sync(self.pit.now)
		self.audio.speaker = band(value, 2) ~= 0
	end
	self.ppiB = value
	self.pit:gate2(band(value, 1) ~= 0)
	if band(value, 0x80) ~= 0 then
		if self.scanCode ~= nil then
			self.keyboardReadyAt = self.pit.now + KEYBOARD_BYTE_CLOCKS
		end
		self.scanCode = nil
		self.pic.pending = band(self.pic.pending, 0xFD)
	end
	if band(value, 0x40) == 0 then
		self.keyboardHeld = true
	elseif self.keyboardHeld then
		self.keyboardHeld = false
		table.insert(self.keyboard, 1, 0xAA)
	end
	if old ~= value then
		self:pumpKeyboard()
	end
end

function Board:readCmos()
	local index = self.cmosIndex
	if index == 0xA then
		-- Report the short update-in-progress interval near the second boundary.
		return self.pit.now % 1_193_182 >= 1_192_900 and 0xA6 or 0x26
	elseif index == 0xB then
		return self.rtcMode or 2
	elseif index == 0xD then
		return 0x80
	elseif index == 0x14 then
		return 0x2D
	end
	local clock = os.date("!*t", self.rtcStart + math.floor(self.pit.now / 1_193_182))
	local value = ({
		[0] = clock.sec,
		[2] = clock.min,
		[4] = clock.hour,
		[6] = clock.wday,
		[7] = clock.day,
		[8] = clock.month,
		[9] = clock.year % 100,
		[0x32] = math.floor(clock.year / 100),
	})[index]
	if value ~= nil then
		return band(self.rtcMode or 2, 4) ~= 0 and value or math.floor(value / 10) * 16 + value % 10
	end
	return buffer.readu8(self.cmos, index)
end

function Board:selectedIdeDisk()
	return if self.ideDevice == 0 then self.hardDisk else self.secondHardDisk
end

function Board:read(port)
	if self.bus.pc and self.hardDisk and AtaDisk.handlesPort(port) then
		local disk = self:selectedIdeDisk()
		return if disk then disk:read(port) else 0
	end
	if self.hardDisk and not self.bus.pc and port >= 0x340 and port <= 0x347 then
		return self.hardDisk:read(port)
	elseif self.soundBlaster and port >= SoundBlaster.BASE and port < SoundBlaster.BASE + 0x10 then
		return self.soundBlaster:read(port)
	elseif port <= 0x0F or (port >= 0x80 and port <= 0x87) then
		if port <= 1 or port == 8 then
			self:syncDmaRefresh()
		end
		return self.dma:read(port)
	elseif port == 0x20 or port == 0x21 then
		return self.pic:read(port)
	elseif port >= 0x40 and port <= 0x43 then
		return self.pit:read(port)
	elseif self.slavePic and (port == 0xA0 or port == 0xA1) then
		return self.slavePic:read(port - 0x80)
	elseif self.cmos and port == 0x71 then
		return self:readCmos()
	elseif self.slavePic and port == 0x92 then
		return self.bus.a20 and 2 or 0
	elseif self.slavePic and port == 0x64 then
		return (self.kbcResponse ~= nil or self.scanCode ~= nil) and 1 or 0
	elseif port == 0x60 then
		if self.atKeyboard then
			local data = self.kbcResponse
			self.kbcResponse = self.kbcNextResponse
			self.kbcNextResponse = nil
			if self.kbcResponse and band(self.kbcConfig, 1) ~= 0 then
				self.pic:request(1)
			end
			if data == nil then
				data = self.scanCode or 0
				self.scanCode = nil
				self.keyboardReadyAt = self.pit.now + KEYBOARD_BYTE_CLOCKS
			end
			return data
		end
		return self.scanCode or 0
	elseif port == 0x61 then
		if self.bus.at then
			return band(self.ppiB, 0xDF) + (self.pit:out2() and 0x20 or 0)
		end
		return self.ppiB
	elseif port == 0x62 then
		local switches = band(self.ppiB, 8) == 0 and band(BOARD_SWITCHES, 15) or bit32.rshift(BOARD_SWITCHES, 4)
		return switches + (self.pit:out2() and 0x20 or 0)
	elseif port == 0x3D4 then
		return self.crtcIndex
	elseif port == 0x3D5 then
		return buffer.readu8(self.crtc, self.crtcIndex)
	elseif port == 0x3DA then
		local frame = self.pit.now % 19912
		return (frame % 76 >= 64 and 1 or 0) + (frame >= 18300 and 8 or 0)
	elseif port >= 0x3F2 and port <= 0x3F5 then
		return self.floppy:read(port)
	elseif self.serialMouse and port >= SerialMouse.BASE and port < SerialMouse.BASE + 8 then
		return self.serialMouse:read(port, self.pit.now)
	end
	return 0xFF
end

function Board:write(port, value)
	if self.bus.pc and self.hardDisk and AtaDisk.handlesPort(port) then
		if port == AtaDisk.CONTROL_PORT then
			if band(self.hardDisk.control, 4) ~= 0 and band(value, 4) == 0 then
				self.ideDevice = 0
			end
			self.hardDisk:write(port, value)
			if self.secondHardDisk then
				self.secondHardDisk:write(port, value)
			end
		else
			if port == AtaDisk.DEVICE_PORT then
				self.ideDevice = bit32.extract(value, 4)
			end
			local disk = self:selectedIdeDisk()
			if disk then
				disk:write(port, value)
			end
		end
		return
	end
	if self.hardDisk and not self.bus.pc and port >= 0x340 and port <= 0x347 then
		self.hardDisk:write(port, value)
	elseif self.soundBlaster and port >= SoundBlaster.BASE and port < SoundBlaster.BASE + 0x10 then
		self.soundBlaster:write(port, value, self.pit.now)
	elseif port <= 0x0F or (port >= 0x80 and port <= 0x87) then
		self:syncDmaRefresh()
		self.dma:write(port, value)
	elseif port == 0x20 or port == 0x21 then
		self.pic:write(port, value)
	elseif port >= 0x40 and port <= 0x43 then
		if port == 0x41 or (port == 0x43 and band(value, 0xC0) == 0x40) then
			self:syncDmaRefresh()
		end
		if self.audio and (port == 0x42 or (port == 0x43 and band(value, 0xC0) == 0x80)) then
			self.audio:sync(self.pit.now)
		end
		self.pit:write(port, value)
	elseif self.slavePic and (port == 0xA0 or port == 0xA1) then
		self.slavePic:write(port - 0x80, value)
	elseif self.cmos and port == 0x70 then
		self.cmosIndex = band(value, 0x7F)
	elseif self.cmos and port == 0x71 then
		buffer.writeu8(self.cmos, self.cmosIndex, value)
		if self.cmosIndex == 0xB then
			self.rtcMode = value
		end
	elseif self.slavePic and port == 0x92 then
		self.bus.a20 = band(value, 2) ~= 0
	elseif self.slavePic and port == 0x64 then
		self:writeKeyboardCommand(value)
	elseif self.atKeyboard and port == 0x60 then
		self:writeKeyboardData(value)
	elseif port == 0x61 then
		self:writePpi(value)
	elseif port == 0x3D4 then
		self.crtcIndex = band(value, 31)
	elseif port == 0x3D5 then
		buffer.writeu8(self.crtc, self.crtcIndex, value)
		self.videoVersion += 1
	elseif port == 0x3D8 then
		self.cgaMode = value
		self.videoVersion += 1
	elseif port == 0x3D9 then
		self.cgaColor = value
		self.videoVersion += 1
	elseif port >= 0x3F2 and port <= 0x3F5 then
		self.floppy:write(port, value)
	elseif self.serialMouse and port >= SerialMouse.BASE and port < SerialMouse.BASE + 8 then
		self.serialMouse:write(port, value, self.pit.now)
	end
end

return Board
