local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

local modules = script.Parent
local GuestAudio = require(modules:WaitForChild("GuestAudio"))
local PcmQueue = require(modules:WaitForChild("PcmQueue"))

local MIN_OUTPUT_SECONDS = 0.064
local MAX_OUTPUT_SECONDS = 0.100
local OUTPUT_MARGIN = 0.012

local AudioOutput = {}
AudioOutput.__index = AudioOutput

local function getVolume(gui)
	local volume = gui:GetAttribute("AudioVolume")
	return if type(volume) == "number" then math.clamp(volume, 0, 1) else 0.65
end

function AudioOutput:startPcm()
	local writer = Instance.new("AudioStreamWriter", self.pcmFolder)
	writer.Layout = Enum.AudioChannelLayout.Mono
	writer.WindowSize = Enum.AudioWindowSize.Large

	local device = Instance.new("AudioDeviceOutput", self.pcmFolder)
	device.Player = Players.LocalPlayer
	local wire = Instance.new("Wire")
	wire.SourceInstance, wire.SourceName = writer, "Output"
	wire.TargetInstance, wire.TargetName = device, "Input"
	wire.Parent = self.pcmFolder

	local capacity = writer:Space()
	assert(capacity > 0, "AudioStreamWriter has no available buffer")
	self.writer, self.wire = writer, wire
	self.capacity = capacity
	self.outputRate = writer.SampleRate
	self.channels = {}
	self.queue = PcmQueue.new(GuestAudio.SAMPLE_RATE, self.outputRate)
	self.refillInterval = 0
	self.writerUnderruns = 0
	local now = os.clock()
	self.lastReport, self.lastDrain, self.lastSubmit = now, now, now
	self.gui:SetAttribute("AudioUnderruns", 0)
	self.gui:SetAttribute("AudioWriterUnderruns", 0)
	self.guestAudio = self.board:enableAudio()
	self.gui:SetAttribute("AudioStatus", "Checking Studio PCM")
end

function AudioOutput:startSpeaker(reason)
	if self.pcmFolder then
		self.pcmFolder:Destroy()
		self.pcmFolder, self.writer, self.wire = nil, nil, nil
		self.board:disableAudio()
		self.guestAudio, self.queue = nil, nil
	end

	-- This built-in Roblox tone provides an approximation of the PC speaker
	-- through the regular Sound API when the live PCM API is unavailable.
	local speaker = Instance.new("Sound")
	speaker.Name = "PCSpeaker"
	speaker.SoundId = "rbxasset://sounds/volume_slider.ogg"
	speaker.Looped = true
	speaker.PlaybackRegionsEnabled = true
	speaker.LoopRegion = NumberRange.new(0.04, 0.10)
	speaker.Parent = self.folder
	self.speaker = speaker
	self.gui:SetAttribute("AudioStatus", "PC speaker only")
	self.gui:SetAttribute("AudioUnderruns", nil)
	self.gui:SetAttribute("AudioWriterUnderruns", nil)
	self.gui:SetAttribute("AudioDetail", reason)
end

function AudioOutput.new(gui, board)
	local folder = Instance.new("Folder")
	folder.Name = "Luau86GuestAudio"
	folder.Parent = SoundService
	local self = setmetatable({ gui = gui, board = board, folder = folder }, AudioOutput)

	gui:SetAttribute("AudioDetail", nil)
	if RunService:IsStudio() then
		self.pcmFolder = Instance.new("Folder", folder)
		local ok, reason = pcall(self.startPcm, self)
		if not ok then
			self:startSpeaker(tostring(reason))
		end
	else
		self:startSpeaker("Raw guest audio is available in Roblox Studio only.")
	end
	return self
end

function AudioOutput:submitPcm(volume)
	local now = os.clock()
	local elapsed = now - self.lastSubmit
	self.lastSubmit = now
	local source, count = self.guestAudio:take()
	self.queue:push(source, count, elapsed)

	local space = math.clamp(self.writer:Space(), 0, self.capacity)
	if self.pcmReady and space == self.capacity and self.spaceAfterWrite < self.capacity then
		self.writerUnderruns += 1
	end
	if self.spaceAfterWrite and self.wire.Connected and space > self.spaceAfterWrite then
		self.lastDrain = now
		if not self.pcmReady then
			self.pcmReady = true
			self.gui:SetAttribute("AudioStatus", "Studio PCM")
		end
	elseif now - self.lastDrain > 1 then
		if not self.wire.Connected then
			error("Roblox did not connect the guest audio output.", 0)
		end
		error("Roblox audio output did not consume any PCM samples.", 0)
	end

	-- Keep enough samples available to bridge uneven calls from Heartbeat.
	-- Reduce the extra delay gradually once the client is running smoothly.
	self.refillInterval = math.max(math.min(elapsed, MAX_OUTPUT_SECONDS), self.refillInterval * math.exp(-elapsed / 2))
	local reserve = math.clamp(self.refillInterval + OUTPUT_MARGIN, MIN_OUTPUT_SECONDS, MAX_OUTPUT_SECONDS)
	local target = math.min(self.capacity, math.ceil(self.outputRate * reserve))
	local frames = target - (self.capacity - space)
	if frames > 0 then
		local bytes = frames * 4
		local output = self.channels[1]
		if not output or buffer.len(output) ~= bytes then
			output = buffer.create(bytes)
			self.channels[1] = output
		end
		self.queue:render(output, frames, volume)
		self.spaceAfterWrite = space - self.writer:Write(self.channels)
	end
	if now - self.lastReport >= 1 then
		self.lastReport = now
		self.gui:SetAttribute("AudioUnderruns", self.queue.underruns)
		self.gui:SetAttribute("AudioWriterUnderruns", self.writerUnderruns)
	end
end

function AudioOutput:submit()
	local volume = getVolume(self.gui)
	if self.writer then
		local ok, reason = pcall(self.submitPcm, self, volume)
		if ok then
			return
		end
		self:startSpeaker(tostring(reason))
	end

	local frequency = self.board:pcSpeakerFrequency()
	local speaker = self.speaker
	if frequency and volume > 0 then
		speaker.Volume = volume * 0.7
		speaker.PlaybackSpeed = math.clamp(frequency / 400, 0.1, 4)
		if not self.speakerActive then
			self.speakerActive = true
			speaker:Play()
		end
	elseif self.speakerActive then
		self.speakerActive = false
		speaker:Stop()
	end
end

function AudioOutput:destroy()
	if self.guestAudio then
		self.board:disableAudio()
	end
	self.folder:Destroy()
end

return AudioOutput
