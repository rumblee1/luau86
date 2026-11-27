local AssetService = game:GetService("AssetService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local modules = script.Parent
local CgaText = require(modules:WaitForChild("CgaText"))
local Machine = require(modules:WaitForChild("Machine"))
local FrameBudget = require(modules:WaitForChild("FrameBudget"))
local decode = require(modules:WaitForChild("MediaDecode"))
local readScreen = require(modules:WaitForChild("TextScreen"))
local scanCodes = require(modules:WaitForChild("Keyboard"))
local AudioOutput = require(modules:WaitForChild("AudioOutput"))

local gui = Instance.new("ScreenGui")
gui.Name = "Luau86"
gui.ResetOnSpawn = false
gui:SetAttribute("AudioVolume", 0.65)

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.92, 0.92)
panel.BackgroundTransparency = 1
panel.Parent = gui

local monitor = Instance.new("Frame")
monitor.AnchorPoint = Vector2.new(0.5, 0)
monitor.Position = UDim2.fromScale(0.5, 0)
monitor.Size = UDim2.new(1, 0, 1, -44)
monitor.BackgroundColor3 = Color3.new(0, 0, 0)
monitor.BorderSizePixel = 0
monitor.Parent = panel

local aspect = Instance.new("UIAspectRatioConstraint")
aspect.AspectRatio = 4 / 3
aspect.AspectType = Enum.AspectType.FitWithinMaxSize
aspect.Parent = monitor

local screen = Instance.new("ImageLabel")
screen.Name = "Display"
screen.Size = UDim2.fromScale(1, 1)
screen.BackgroundTransparency = 1
screen.ResampleMode = Enum.ResamplerMode.Pixelated
screen.Visible = false
screen.Parent = monitor

local text = Instance.new("TextLabel")
text.Size = UDim2.new(1, -24, 1, -24)
text.Position = UDim2.fromOffset(12, 12)
text.BackgroundTransparency = 1
text.TextColor3 = Color3.fromRGB(224, 226, 224)
text.Font = Enum.Font.Code
text.TextSize = 16
text.TextXAlignment = Enum.TextXAlignment.Left
text.TextYAlignment = Enum.TextYAlignment.Top
text.TextWrapped = true
text.Text = ""
text.Parent = monitor

local power = Instance.new("TextButton")
power.AnchorPoint = Vector2.new(0.5, 1)
power.Position = UDim2.fromScale(0.5, 1)
power.Size = UDim2.fromOffset(128, 36)
power.Text = "Power on"
power.Parent = panel

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local media = modules:WaitForChild("media", 5)
local firmwareFolder = media and (media:FindFirstChild("Firmware") or media)
local seaBiosSource = firmwareFolder and firmwareFolder:WaitForChild("SeaBios", 5)
local seaVgaSource = firmwareFolder and firmwareFolder:WaitForChild("SeaVgaBios", 5)
local fontSource = firmwareFolder and firmwareFolder:WaitForChild("Font", 5)
if not seaBiosSource or not seaVgaSource or not fontSource then
	text.Text = "Firmware is missing. Run python3 tools/media.py import-firmware --help."
	power.Visible = false
	return
end

local floppy = media:FindFirstChild("vga_disk")
local profiles = {}
local function addProfile(name, diskName, bootFloppy)
	local disk = media:FindFirstChild(diskName)
	if disk or bootFloppy then
		table.insert(profiles, { name = name, disk = disk, floppy = bootFloppy })
	end
end

addProfile("FreeDOS", "vga_hard_disk", floppy)
if media:FindFirstChild("full_disk") then
	addProfile("FreeDOS Full", "full_disk", floppy)
end
addProfile("Linux", "linux_disk")
if media:FindFirstChild("vga_windows31_disk") then
	addProfile("Windows 3.1", "vga_windows31_disk", floppy)
end
addProfile("GRUB", "grub_disk")

local imported = media:FindFirstChild("Imported")
if imported then
	local folders = imported:GetChildren()
	table.sort(folders, function(a, b)
		return a.Name < b.Name
	end)
	for _, folder in folders do
		local profile = folder:FindFirstChild("Profile")
		if profile and profile:IsA("ModuleScript") then
			local disk = folder:FindFirstChild("HardDisk")
			local bootFloppy = folder:FindFirstChild("Floppy")
			local secondDisk = folder:FindFirstChild("SecondHardDisk")
			if disk or bootFloppy then
				local ok, name = pcall(require, profile)
				if ok and type(name) == "string" then
					table.insert(profiles, { name = name, disk = disk, floppy = bootFloppy, secondDisk = secondDisk })
				end
			end
		end
	end
end

if #profiles == 0 then
	text.Text = "No boot disk found. Run python3 tools/media.py --help to import your own disk."
	power.Visible = false
	return
end

text.Text = "Ready to boot " .. profiles[1].name
local selector
if #profiles > 1 then
	selector = power:Clone()
	selector.Name = "MachineProfile"
	selector.AnchorPoint = Vector2.new(1, 1)
	selector.Position = UDim2.new(0.5, -5, 1, 0)
	selector.Size = UDim2.fromOffset(148, 36)
	selector.TextTruncate = Enum.TextTruncate.AtEnd
	selector.Text = profiles[1].name
	selector.Parent = panel
	power.AnchorPoint = Vector2.new(0, 1)
	power.Position = UDim2.new(0.5, 5, 1, 0)
end

local renderer = CgaText.new(decode(require(fontSource)))
local image, visibleImage
local graphicsImages = {}

local function showImage(display)
	if display ~= visibleImage then
		screen.ImageContent = Content.fromObject(display)
		visibleImage = display
	end
	if not screen.Visible then
		screen.Visible = true
		text.Text = ""
	end
end

local ok, result = pcall(AssetService.CreateEditableImage, AssetService, {
	Size = Vector2.new(CgaText.WIDTH, CgaText.HEIGHT),
})
if ok and result then
	image = result
else
	warn("CGA image unavailable. Using the text display.", result)
end

local performance = if RunService:IsStudio()
	then require(modules:WaitForChild("Performance")).new(gui, Machine.PIT_HZ)
	else nil

local machine, failed, loading
local audioOutput

local function stopAudio()
	if audioOutput then
		audioOutput:destroy()
		audioOutput = nil
	end
end
local selectedProfile, runningProfile = 1, nil
local frameBudget = FrameBudget.new(Machine.PIT_HZ)
local held, scanCount = {}, {}
local mouseButtons, mouseDX, mouseDY = 0, 0, 0
local lastMousePosition
local windowFocused = true
local displayedVersion = -1
local displayedRegisters = -1

local camera, previousCameraType

local function restoreCamera()
	if camera and camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = previousCameraType
	end
	camera, previousCameraType = nil, nil
end

local function captureCamera()
	local current = workspace.CurrentCamera
	if current == camera then
		return
	end
	restoreCamera()
	if current then
		camera, previousCameraType = current, current.CameraType
		current.CameraType = Enum.CameraType.Scriptable
	end
end

local function loadDisk(folder)
	local index = require(assert(folder:WaitForChild("Index", 10), "Missing disk index"))
	local diskImage = buffer.create(index.size)
	for number, part in index.parts do
		local source = assert(folder:WaitForChild(part[2], 10), "Missing disk part " .. part[2])
		decode(require(source), diskImage, part[1])
		if number % 8 == 0 then
			task.wait()
		end
	end
	return diskImage
end

local function startMachine(profile)
	if machine and selectedProfile == runningProfile then
		return machine:restart()
	end

	local firmware = loadDisk(seaBiosSource)
	local vgaRom = decode(require(seaVgaSource))
	local floppyImage = profile.floppy and loadDisk(profile.floppy) or nil
	local hardDisk = profile.disk and loadDisk(profile.disk) or nil
	local secondHardDisk = profile.secondDisk and loadDisk(profile.secondDisk) or nil
	return Machine.newSeaBios(firmware, vgaRom, floppyImage, hardDisk, secondHardDisk)
end

if selector then
	selector.Activated:Connect(function()
		if loading then
			return
		end
		selectedProfile = selectedProfile % #profiles + 1
		selector.Text = profiles[selectedProfile].name
		if not machine then
			text.Text = "Ready to boot " .. profiles[selectedProfile].name
		end
		power.Text = selectedProfile == runningProfile and "Restart" or "Power on"
	end)
end

local function startRuntime()
	audioOutput = AudioOutput.new(gui, machine.board)
	frameBudget = FrameBudget.new(Machine.PIT_HZ)
	table.clear(held)
	table.clear(scanCount)
	mouseButtons, mouseDX, mouseDY = 0, 0, 0
	lastMousePosition = nil
	displayedVersion, displayedRegisters = -1, -1
	text.Text = ""
	text.TextWrapped = false
end

power.Activated:Connect(function()
	if loading then
		return
	end
	loading = true
	power.Text = "Loading…"
	screen.Visible = false
	text.TextScaled = false
	text.TextWrapped = true
	text.Text = "Loading " .. profiles[selectedProfile].name .. "…"
	stopAudio()
	local poweredAt = os.clock()
	local profile = profiles[selectedProfile]
	local started, result = pcall(startMachine, profile)
	loading = false
	if not gui.Parent then
		return
	end
	if not started then
		failed = true
		restoreCamera()
		power.Modal = false
		text.Text = tostring(result)
		power.Text = "Retry"
		warn(result)
		return
	end

	machine = result
	runningProfile = selectedProfile
	startRuntime()
	if performance then
		performance:start(profile.name, poweredAt, os.clock())
	end
	failed = false
	captureCamera()
	power.Text = "Restart"
	power.Modal = true
end)

local cameraConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if machine and not failed then
		captureCamera()
	end
end)

local ACTION = "Luau86Keyboard"
local keys = {}
for _, key in Enum.KeyCode:GetEnumItems() do
	if scanCodes[key.Name] then
		table.insert(keys, key)
	end
end

local function releaseKey(key)
	local scan = held[key]
	if scan then
		held[key] = nil
		scanCount[scan] -= 1
		if scanCount[scan] == 0 and machine and not failed then
			machine.board:queueScanCode(scan + 0x80)
		end
	end
end

local function guestAcceptsInput()
	return machine ~= nil and not failed and not loading and UserInputService:GetFocusedTextBox() == nil
end

local mouseButton = {
	[Enum.UserInputType.MouseButton1] = 0x20,
	[Enum.UserInputType.MouseButton2] = 0x10,
}

local function overMonitor(position)
	local origin, size = monitor.AbsolutePosition, monitor.AbsoluteSize
	return position.X >= origin.X
		and position.X < origin.X + size.X
		and position.Y >= origin.Y
		and position.Y < origin.Y + size.Y
end

local function sendMouse()
	local board = machine and machine.board
	if board and board.serialMouse and not failed then
		local movedAt = if performance and (mouseDX ~= 0 or mouseDY ~= 0) then os.clock() else nil
		board.serialMouse:move(mouseDX, mouseDY, mouseButtons, board.pit.now, movedAt)
	end
	mouseDX, mouseDY = 0, 0
end

local function trackMouse(position)
	local vga = machine and machine.bus.vga
	if not windowFocused or not guestAcceptsInput() or not vga or not vga.active or not overMonitor(position) then
		lastMousePosition = nil
		return false
	end

	-- Track the unlocked cursor by position. Only consecutive samples over
	-- the display should contribute relative movement to the guest.
	if lastMousePosition then
		mouseDX = math.clamp(mouseDX + position.X - lastMousePosition.X, -128, 127)
		mouseDY = math.clamp(mouseDY + position.Y - lastMousePosition.Y, -128, 127)
	end
	lastMousePosition = position
	return true
end

-- Keep player controls out of the guest. Read keyboard events independently
-- of action priority so camera bindings cannot consume guest keystrokes.
ContextActionService:BindActionAtPriority(ACTION, function()
	return guestAcceptsInput() and Enum.ContextActionResult.Sink or Enum.ContextActionResult.Pass
end, false, Enum.ContextActionPriority.High.Value, table.unpack(keys))

local keyDown = UserInputService.InputBegan:Connect(function(input)
	local button = mouseButton[input.UserInputType]
	if button and trackMouse(input.Position) then
		mouseButtons = bit32.bor(mouseButtons, button)
		sendMouse()
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard or not guestAcceptsInput() then
		return
	end
	local key = input.KeyCode
	local scan = scanCodes[key.Name]
	if scan and not held[key] then
		held[key] = scan
		scanCount[scan] = (scanCount[scan] or 0) + 1
		if scanCount[scan] == 1 then
			if performance and scan == scanCodes.Return and profiles[runningProfile].name == "FreeDOS" then
				local vga = machine.bus.vga
				if vga and not vga.active then
					local screenText = readScreen(machine.bus, machine.board):gsub("%s+$", "")
					local line = screenText:match("[^\n]+$") or ""
					local program = line:lower():match("^[a-z]:[^>]*>%s*(%S+)")
					if
						program == "doom"
						or program == "doom.exe"
						or program == "doomfast"
						or program == "doomfast.bat"
						or program == "doomtiny"
						or program == "doomtiny.bat"
						or program == "fastdoom"
						or program == "fastdoom.bat"
					then
						performance:mark("Doom command")
					end
				end
			end
			machine.board:queueScanCode(scan)
		end
	end
end)

local keyUp = UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		releaseKey(input.KeyCode)
	else
		local button = mouseButton[input.UserInputType]
		if button and bit32.band(mouseButtons, button) ~= 0 then
			mouseButtons = bit32.band(mouseButtons, bit32.bnot(button))
			sendMouse()
		end
	end
end)

local function releaseAllInputs()
	for key in held do
		releaseKey(key)
	end
	lastMousePosition = nil
	mouseDX, mouseDY = 0, 0
	if mouseButtons ~= 0 then
		mouseButtons = 0
		sendMouse()
	end
end

local focusLost = UserInputService.WindowFocusReleased:Connect(function()
	windowFocused = false
	releaseAllInputs()
end)
local focusGained = UserInputService.WindowFocused:Connect(function()
	windowFocused = true
end)
local textFocusConnection = UserInputService.TextBoxFocused:Connect(releaseAllInputs)

local function runSlice(pit, target, deadline)
	while pit.now < target and os.clock() < deadline do
		for _ = 1, 64 do
			if pit.now >= target then
				break
			end
			if machine:step(target - pit.now) then
				return true
			end
		end
	end
end

local heartbeat = RunService.Heartbeat:Connect(function(elapsed)
	if not machine or failed or loading then
		return
	end
	local vga = machine.bus.vga
	if vga and vga.active and windowFocused then
		local inset = GuiService:GetGuiInset()
		trackMouse(UserInputService:GetMouseLocation() - inset)
	else
		lastMousePosition = nil
	end
	if mouseDX ~= 0 or mouseDY ~= 0 then
		sendMouse()
	end

	local adaptive = not performance or performance.folder:GetAttribute("AdaptiveCpu") ~= false
	local credit, budget = frameBudget:beginFrame(elapsed, adaptive, vga and vga.active and vga.indexed)
	local pit = machine.board.pit
	local startingClocks = pit.now
	local startedAt = os.clock()
	debug.profilebegin("Luau86 CPU")
	local ran, resetOrError = pcall(runSlice, pit, startingClocks + credit, startedAt + budget)
	debug.profileend()
	local devicesStartedAt = os.clock()
	local cpuSeconds = devicesStartedAt - startedAt
	if not ran then
		failed = true
		stopAudio()
		restoreCamera()
		screen.Visible = false
		text.TextScaled = false
		text.TextWrapped = true
		text.Text = tostring(resetOrError)
		power.Modal = false
		warn(resetOrError)
		return
	elseif resetOrError then
		stopAudio()
		startRuntime()
		if performance then
			performance:start(profiles[runningProfile].name, startedAt, os.clock())
		end
		return
	end

	if audioOutput then
		debug.profilebegin("Luau86 Audio")
		local ok, reason = pcall(audioOutput.submit, audioOutput)
		debug.profileend()
		if not ok then
			stopAudio()
			gui:SetAttribute("AudioStatus", "Audio unavailable")
			gui:SetAttribute("AudioDetail", tostring(reason))
			warn("Luau86 audio output stopped.", reason)
		end
	end

	local presented = false
	local vgaSeconds = 0
	if vga and vga.active then
		local vgaStartedAt = if performance then os.clock() else nil
		local graphicsImage = graphicsImages[vga.width]
		if graphicsImage == nil then
			local created, result = pcall(AssetService.CreateEditableImage, AssetService, {
				Size = Vector2.new(vga.width, vga.height),
			})
			graphicsImage = if created and result then result else false
			graphicsImages[vga.width] = graphicsImage
			if not graphicsImage then
				warn("VGA image unavailable.", result)
			end
		end
		if graphicsImage then
			showImage(graphicsImage)
			debug.profilebegin("Luau86 VGA")
			local convertStartedAt = if performance then os.clock() else nil
			debug.profilebegin("Luau86 VGA Convert")
			local _, rectangles = vga:render()
			debug.profileend()
			if rectangles and #rectangles > 0 then
				presented = true
				local uploadStartedAt = if performance then os.clock() else nil
				local uploadBytes = 0
				debug.profilebegin("Luau86 VGA Upload")
				for index = 1, #rectangles, 4 do
					local x, y = rectangles[index], rectangles[index + 1]
					local width, height = rectangles[index + 2] - x, rectangles[index + 3] - y
					local pixels = vga:pixelsForRect(x, y, width, height)
					graphicsImage:WritePixelsBuffer(Vector2.new(x, y), Vector2.new(width, height), pixels)
					if uploadStartedAt then
						uploadBytes += buffer.len(pixels)
					end
				end
				debug.profileend()
				if uploadStartedAt then
					performance:recordVga(uploadStartedAt - convertStartedAt, os.clock() - uploadStartedAt, uploadBytes)
				end
			end
			debug.profileend()
		else
			screen.Visible = false
			text.Text = "VGA display requires EditableImage."
			displayedVersion, displayedRegisters = -1, -1
		end
		if vgaStartedAt then
			vgaSeconds = os.clock() - vgaStartedAt
		end
	elseif image then
		showImage(image)
		local y, height, pixels = renderer:update(machine.bus, machine.board)
		if y then
			image:WritePixelsBuffer(Vector2.new(0, y), Vector2.new(CgaText.WIDTH, height), pixels)
		end
	elseif machine.bus.videoVersion ~= displayedVersion or machine.board.videoVersion ~= displayedRegisters then
		screen.Visible = false
		text.TextScaled = true
		text.Text = readScreen(machine.bus, machine.board)
		displayedVersion = machine.bus.videoVersion
		displayedRegisters = machine.board.videoVersion
	end
	local clocks = pit.now - startingClocks
	frameBudget:endFrame(clocks, cpuSeconds, os.clock() - devicesStartedAt)
	if performance then
		local mouse = machine.board.serialMouse
		performance:frame(elapsed, clocks, cpuSeconds, vgaSeconds, budget, presented, mouse and mouse.lastMotionReadAt)
	end
end)

gui.Destroying:Connect(function()
	stopAudio()
	ContextActionService:UnbindAction(ACTION)
	cameraConnection:Disconnect()
	restoreCamera()
	keyDown:Disconnect()
	keyUp:Disconnect()
	focusLost:Disconnect()
	focusGained:Disconnect()
	textFocusConnection:Disconnect()
	heartbeat:Disconnect()
	if image then
		image:Destroy()
	end
	for _, display in graphicsImages do
		if display then
			display:Destroy()
		end
	end
end)
