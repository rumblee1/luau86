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
local StatsOverlay = require(modules:WaitForChild("StatsOverlay"))
local Debugger = require(modules:WaitForChild("Debugger"))

local gui = Instance.new("ScreenGui")
gui.Name = "Luau86"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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

local controls = Instance.new("Frame")
controls.Name = "Controls"
controls.Size = UDim2.fromScale(1, 1)
controls.BackgroundTransparency = 1
controls.ZIndex = 2
controls.Parent = panel

local power = Instance.new("TextButton")
power.AnchorPoint = Vector2.new(0.5, 1)
power.Position = UDim2.fromScale(0.5, 1)
power.Size = UDim2.fromOffset(128, 36)
power.Text = "Power on"
power.ZIndex = controls.ZIndex
power.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
power.BackgroundTransparency = 0
power.TextColor3 = Color3.fromRGB(220, 220, 220)
power.BorderSizePixel = 0
power.FontFace = Font.fromEnum(Enum.Font.BuilderSansMedium)
power.TextSize = 14
power.Parent = controls

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
local selector, profileMenu, profileArrow, profileDismiss
local profileOptions = {}
local PROFILE_ROW = 28
if #profiles > 1 then
	selector = power:Clone()
	selector.Name = "MachineProfile"
	selector.AnchorPoint = Vector2.new(1, 1)
	selector.Position = UDim2.new(0.5, -5, 1, 0)
	selector.Size = UDim2.fromOffset(148, 36)
	selector.TextTruncate = Enum.TextTruncate.AtEnd
	selector.Text = profiles[1].name
	selector.TextXAlignment = Enum.TextXAlignment.Center
	selector.Active = true
	selector.Interactable = true
	selector.ZIndex = 12
	selector.Parent = controls

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 22)
	padding.Parent = selector

	-- A font-independent chevron. It never receives mouse input.
	profileArrow = Instance.new("Frame")
	profileArrow.Name = "Chevron"
	profileArrow.AnchorPoint = Vector2.new(1, 0.5)
	profileArrow.Position = UDim2.fromOffset(0, 0)
	profileArrow.Size = UDim2.fromOffset(9, 9)
	profileArrow.BackgroundTransparency = 1
	profileArrow.Active = false
	profileArrow.Interactable = false
	profileArrow.ZIndex = 13
	profileArrow.Parent = controls
	for index = 1, 2 do
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.fromOffset(if index == 1 then 3 else 6, 4)
		line.Size = UDim2.fromOffset(5, 1)
		line.Rotation = if index == 1 then 45 else -45
		line.BackgroundColor3 = power.TextColor3
		line.BackgroundTransparency = 0.1
		line.BorderSizePixel = 0
		line.Active = false
		line.Interactable = false
		line.ZIndex = 13
		line.Parent = profileArrow
	end

	-- Let Roblox perform hit testing rather than mixing GUI coordinate spaces.
	profileDismiss = Instance.new("TextButton")
	profileDismiss.Name = "ProfileDismiss"
	profileDismiss.AnchorPoint = Vector2.new(0.5, 0.5)
	profileDismiss.Position = UDim2.fromScale(0.5, 0.5)
	profileDismiss.Size = UDim2.fromScale(1 / 0.92, 1 / 0.92)
	profileDismiss.BackgroundTransparency = 1
	profileDismiss.Text = ""
	profileDismiss.AutoButtonColor = false
	profileDismiss.Active = true
	profileDismiss.Selectable = false
	profileDismiss.Visible = false
	profileDismiss.ZIndex = 10
	profileDismiss.Parent = controls

	profileMenu = Instance.new("ScrollingFrame")
	profileMenu.Name = "ProfileMenu"
	profileMenu.BackgroundColor3 = power.BackgroundColor3
	profileMenu.BorderSizePixel = 0
	profileMenu.ScrollBarThickness = 4
	profileMenu.ScrollBarImageColor3 = power.TextColor3:Lerp(power.BackgroundColor3, 0.3)
	profileMenu.ScrollingDirection = Enum.ScrollingDirection.Y
	profileMenu.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	profileMenu.CanvasSize = UDim2.fromOffset(0, #profiles * PROFILE_ROW)
	profileMenu.Active = true
	profileMenu.Visible = false
	profileMenu.ZIndex = 11
	profileMenu.ClipsDescendants = true
	profileMenu.Parent = controls
	for index, profile in profiles do
		local option = power:Clone()
		option.Name = "Profile" .. index
		option.AnchorPoint = Vector2.zero
		option.Position = UDim2.fromOffset(0, (index - 1) * PROFILE_ROW)
		option.Size = UDim2.new(1, 0, 0, PROFILE_ROW)
		option.Text = "  " .. profile.name
		option.TextXAlignment = Enum.TextXAlignment.Left
		option.TextTruncate = Enum.TextTruncate.AtEnd
		option.ZIndex = 12
		option.Active = true
		option.Interactable = true
		option.Parent = profileMenu
		profileOptions[index] = option
	end
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

local stats = StatsOverlay.new(controls, power)
local debugger = Debugger.new(controls, power)

local details = power:Clone()
details.Name = "Details"
details.Text = "Details"
details.Parent = controls
details.Visible = false

local debugButton = power:Clone()
debugButton.Name = "DebuggerButton"
debugButton.Text = "Debug"
debugButton.Parent = controls
debugButton.Visible = false

local function closeProfileMenu()
	if profileMenu then
		profileMenu.Visible = false
		profileDismiss.Visible = false
		profileArrow.Rotation = 0
	end
end

local function positionProfileMenu()
	if not profileMenu then return end
	local x, bottom = selector.Position.X.Offset, selector.Position.Y.Offset
	local top = bottom - selector.Size.Y.Offset
	profileArrow.Position = UDim2.fromOffset(x + selector.Size.X.Offset - 12, (top + bottom) / 2)
	local above, below = math.max(0, top - 4), math.max(0, panel.AbsoluteSize.Y - bottom - 4)
	local desired = math.min(#profiles * PROFILE_ROW, 224)
	local openAbove = above >= desired or above >= below
	local height = math.min(desired, if openAbove then above else below)
	if height < 1 then closeProfileMenu(); return end
	profileMenu.Position = UDim2.fromOffset(x, if openAbove then top - height - 4 else bottom + 4)
	profileMenu.Size = UDim2.fromOffset(selector.Size.X.Offset, height)
end

local GAP = 8
local ASPECT = 4 / 3
local CONTROL_HEIGHT = 44
local BUTTON_HEIGHT = 36

local function placeControls(centerX, bottomY, availableWidth)
	local buttons = if selector then { selector, power, details, debugButton } else { power, details, debugButton }
	local widths = if selector then { 148, 110, 82, 72 } else { 110, 82, 72 }
	local total = GAP * (#buttons - 1)
	for _, width in widths do
		total += width
	end
	local scale = math.min(1, math.max(0, availableWidth - GAP * (#buttons - 1)) / (total - GAP * (#buttons - 1)))
	total = (total - GAP * (#buttons - 1)) * scale + GAP * (#buttons - 1)
	local x = centerX - total / 2
	for index, item in buttons do
		local width = widths[index] * scale
		item.AnchorPoint = Vector2.new(0, 1)
		item.Position = UDim2.fromOffset(x, bottomY)
		item.Size = UDim2.fromOffset(width, BUTTON_HEIGHT)
		x += width + GAP
	end
end

local function updateLayout()
	local group = if debugger.group.Visible then debugger.group else stats.group
	local w, h = panel.AbsoluteSize.X, panel.AbsoluteSize.Y - CONTROL_HEIGHT
	if w <= 0 or h <= GAP then
		return
	end

	local displayWidth, displayHeight, displayX, displayY
	local controlY
	if not group.Visible then
		displayWidth = math.min(w, h * ASPECT)
		displayHeight = displayWidth / ASPECT
		displayX = w / 2
		displayY = (h - displayHeight) / 2
		controlY = displayY + displayHeight + CONTROL_HEIGHT
	elseif w >= 760 then
		local statsWidth = if debugger.group.Visible then math.clamp(w * 0.39, 380, 540) else math.clamp(w * 0.32, 340, 440)
		displayWidth = math.min(w - statsWidth - GAP, h * ASPECT)
		displayHeight = displayWidth / ASPECT
		local left = (w - displayWidth - GAP - statsWidth) / 2
		displayX = left + displayWidth / 2
		displayY = (h - displayHeight) / 2
		group.Position = UDim2.fromOffset(left + displayWidth + GAP, displayY)
		group.Size = UDim2.fromOffset(statsWidth, displayHeight)
		controlY = displayY + displayHeight + CONTROL_HEIGHT
	else
		local statsHeight = if debugger.group.Visible then (h - GAP) * 0.65 else math.min((h - GAP) * 0.48, 400)
		local statsWidth = math.min(w, if debugger.group.Visible then 540 else 440)
		displayWidth = math.min(w, (h - statsHeight - GAP) * ASPECT)
		displayHeight = displayWidth / ASPECT
		displayX = w / 2
		displayY = (h - displayHeight - GAP - statsHeight) / 2
		controlY = displayY + displayHeight + CONTROL_HEIGHT
		group.Position = UDim2.fromOffset((w - statsWidth) / 2, controlY + GAP)
		group.Size = UDim2.fromOffset(statsWidth, statsHeight)
	end

	monitor.Position = UDim2.fromOffset(displayX, displayY)
	monitor.Size = UDim2.fromOffset(displayWidth, displayHeight)
	local buttonSpace = if group.Visible and w >= 760 then displayWidth else w
	placeControls(displayX, controlY, buttonSpace)
	positionProfileMenu()
	details.BackgroundColor3 = if stats.group.Visible then power.BackgroundColor3:Lerp(power.TextColor3, 0.15) else power.BackgroundColor3
	debugButton.BackgroundColor3 = if debugger.group.Visible then power.BackgroundColor3:Lerp(power.TextColor3, 0.15) else power.BackgroundColor3
end

local sizeConnection = panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateLayout)
local statsVisibilityConnection = stats.group:GetPropertyChangedSignal("Visible"):Connect(updateLayout)
local debugVisibilityConnection = debugger.group:GetPropertyChangedSignal("Visible"):Connect(updateLayout)
updateLayout()

local machine, failed, loading
local audioOutput
local wasPaused = false
local releaseAllInputs

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

local DISK_LOAD_SLICE = 0.005

local function loadDisk(folder)
	local index = require(assert(folder:WaitForChild("Index", 10), "Missing disk index"))
	local diskImage = buffer.create(index.size)
	local deadline = os.clock() + DISK_LOAD_SLICE
	for number, part in index.parts do
		local source = assert(folder:WaitForChild(part[2], 10), "Missing disk part " .. part[2])
		decode(require(source), diskImage, part[1])
		if number < #index.parts and os.clock() >= deadline then
			task.wait()
			deadline = os.clock() + DISK_LOAD_SLICE
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
	profileDismiss.Activated:Connect(closeProfileMenu)
	selector.Activated:Connect(function()
		if loading then return end
		if profileMenu.Visible then closeProfileMenu(); return end
		if releaseAllInputs then releaseAllInputs() end
		for index, option in profileOptions do
			option.BackgroundColor3 = if index == selectedProfile
				then power.BackgroundColor3:Lerp(power.TextColor3, 0.17) else power.BackgroundColor3
		end
		profileMenu.Visible = true
		profileDismiss.Visible = true
		profileArrow.Rotation = 180
		positionProfileMenu()
	end)
	for index, option in profileOptions do
		option.Activated:Connect(function()
			if loading then return end
			selectedProfile = index
			selector.Text = profiles[index].name
			closeProfileMenu()
			if not machine then
				text.Text = "Ready to boot " .. profiles[index].name
			end
			power.Text = selectedProfile == runningProfile and "Restart" or "Power on"
		end)
	end
end

local function startRuntime()
	debugger:setMachine(machine)
	wasPaused = false
	stats:reset(machine.cpu)
	local mouse = machine.board.serialMouse
	if mouse then
		mouse:useInteractiveTiming()
	end
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
	closeProfileMenu()
	debugger:setMachine(nil)
	stats:reset(nil, "Loading…")
	power.Text = "Loading…"
	screen.Visible = false
	text.TextScaled = false
	text.TextWrapped = true
	text.Text = "Loading " .. profiles[selectedProfile].name .. "…"
	stopAudio()
	local profile = profiles[selectedProfile]
	local started, result = pcall(startMachine, profile)
	loading = false
	if not gui.Parent then
		return
	end
	if not started then
		failed = true
		stats:reset(nil, "Emulator stopped")
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
local STATS_KEY = Enum.KeyCode.RightAlt
local statsKeyDown = false
local rightAltHeld = false
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
	return machine ~= nil and not failed and not loading and not debugger.paused and not (profileMenu and profileMenu.Visible) and UserInputService:GetFocusedTextBox() == nil
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
		local movedAt = if stats.group.Visible and (mouseDX ~= 0 or mouseDY ~= 0) then os.clock() else nil
		board.serialMouse:move(mouseDX, mouseDY, mouseButtons, board.pit.now, movedAt)
	end
	mouseDX, mouseDY = 0, 0
end

local function trackMouse(position)
	local vga = machine and machine.bus.vga
	if
		not windowFocused
		or not guestAcceptsInput()
		or not vga
		or not vga.active
		or not overMonitor(position)
		or stats:contains(position)
		or debugger:contains(position)
	then
		lastMousePosition = nil
		return false
	end

	-- Track the unlocked cursor by position. Only consecutive samples over
	-- the display should contribute relative movement to the guest.
	if lastMousePosition then
		mouseDX += position.X - lastMousePosition.X
		mouseDY += position.Y - lastMousePosition.Y
	end
	lastMousePosition = position
	return true
end

-- Keep player controls out of the guest. Read keyboard events independently
-- of action priority so camera bindings cannot consume guest keystrokes.
ContextActionService:BindActionAtPriority(ACTION, function()
	return guestAcceptsInput() and Enum.ContextActionResult.Sink or Enum.ContextActionResult.Pass
end, false, Enum.ContextActionPriority.High.Value, table.unpack(keys))

local function toggleDetails()
	closeProfileMenu()
	if debugger.group.Visible then debugger:setVisible(false, if not failed and not loading then machine else nil) end
	local status = if loading
		then "Loading…"
		elseif failed then "Emulator stopped"
		elseif not machine then "Power on to view stats"
		else nil
	stats:toggle(if status then nil else machine.cpu, status)
end

details.Activated:Connect(toggleDetails)
stats.close.Activated:Connect(toggleDetails)

local function toggleDebugger()
	closeProfileMenu()
	if debugger.group.Visible then
		debugger:setVisible(false, if not failed and not loading then machine else nil)
	else
		if stats.group.Visible then stats:toggle(nil) end
		if releaseAllInputs then releaseAllInputs() end
		debugger:setVisible(true, if not failed and not loading then machine else nil)
	end
end

debugButton.Activated:Connect(toggleDebugger)
debugger.close.Activated:Connect(toggleDebugger)

local keyDown = UserInputService.InputBegan:Connect(function(input)
	if profileMenu and profileMenu.Visible then
		if input.KeyCode == Enum.KeyCode.Escape then
			closeProfileMenu()
			return
		end
		-- The dismiss button handles outside clicks on release.
		return
	end
	if input.KeyCode == STATS_KEY then
		rightAltHeld = true
		details.Visible = true
		debugButton.Visible = true
		return
	end
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
			machine.board:queueScanCode(scan)
		end
	end
end)

local keyUp = UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == STATS_KEY then
		rightAltHeld = false
		details.Visible = false
		debugButton.Visible = false
	elseif input.UserInputType == Enum.UserInputType.Keyboard then
		releaseKey(input.KeyCode)
	else
		local button = mouseButton[input.UserInputType]
		if button and bit32.band(mouseButtons, button) ~= 0 then
			mouseButtons = bit32.band(mouseButtons, bit32.bnot(button))
			sendMouse()
		end
	end
end)

releaseAllInputs = function()
	rightAltHeld = false
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
	closeProfileMenu()
	releaseAllInputs()
end)
local focusGained = UserInputService.WindowFocused:Connect(function()
	windowFocused = true
end)
local textFocusConnection = UserInputService.TextBoxFocused:Connect(releaseAllInputs)

local renderStatsConnection = RunService.RenderStepped:Connect(function(elapsed)
	if stats.group.Visible then
		stats:recordRender(elapsed)
	end
end)

local lastDebugRefresh = 0
local heartbeat = RunService.Heartbeat:Connect(function(elapsed)
	if not machine or failed or loading then
		return
	end
	if debugger.paused ~= wasPaused then
		wasPaused = debugger.paused
		frameBudget = FrameBudget.new(Machine.PIT_HZ)
		if wasPaused then
			releaseAllInputs()
			stopAudio()
		elseif not audioOutput then
			local ok, output = pcall(AudioOutput.new, gui, machine.board)
			if ok then audioOutput = output else warn(output) end
		end
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

	local collectStats = stats.group.Visible and not debugger.paused
	if collectStats then stats:attachDisks(machine.board) end
	local credit, budget = 0, 0
	local stepping = debugger.paused and debugger.stepPending
	local runCpu = not debugger.paused
	if runCpu then
		credit, budget = frameBudget:beginFrame(elapsed, true, vga and vga.active and vga.indexed)
	end
	local pit = machine.board.pit
	local startingClocks = pit.now
	local startedAt = os.clock()
	local ran, resetOrError = true, nil
	if stepping then
		ran, resetOrError = debugger:singleStep()
	elseif runCpu then
		debug.profilebegin("Luau86 CPU")
		local stopReason
		ran, resetOrError, stopReason = pcall(machine.runSlice, machine, startingClocks + credit, startedAt + budget, debugger:breakpointHook())
		debug.profileend()
		if ran and stopReason == "breakpoint" then
			debugger:breakpointStopped()
		end
	end
	local devicesStartedAt = os.clock()
	local cpuSeconds = devicesStartedAt - startedAt
	if not ran then
		failed = true
		debugger:setMachine(nil)
		stats:reset(nil, "Emulator stopped")
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
		return
	end

	if audioOutput and not debugger.paused then
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

	local audioSeconds = if collectStats and audioOutput then os.clock() - devicesStartedAt else nil
	local presented = false
	if collectStats and not (vga and vga.active) then stats.deferSeconds = 0 end
	if vga and vga.active then
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
			local delay = not debugger.paused and graphicsImage == visibleImage
				and vga:shouldDelayPresent(elapsed, pit.now < startingClocks + credit, mouseButtons ~= 0)
			showImage(graphicsImage)
			if collectStats then stats:recordPresentation(elapsed, delay) end
			if not delay then
				debug.profilebegin("Luau86 VGA")
				local convertStartedAt = if collectStats then os.clock() else nil
				debug.profilebegin("Luau86 VGA Convert")
				local _, rectangles = vga:render()
				debug.profileend()
				if rectangles and #rectangles > 0 then
					presented = true
					local uploadStartedAt = if collectStats then os.clock() else nil
					debug.profilebegin("Luau86 VGA Upload")
					for index = 1, #rectangles, 4 do
						local x, y = rectangles[index], rectangles[index + 1]
						local width, height = rectangles[index + 2] - x, rectangles[index + 3] - y
						local pixels = vga:pixelsForRect(x, y, width, height)
						graphicsImage:WritePixelsBuffer(Vector2.new(x, y), Vector2.new(width, height), pixels)
					end
					debug.profileend()
					if uploadStartedAt then
						stats:recordVga(uploadStartedAt - convertStartedAt, os.clock() - uploadStartedAt)
					end
				end
				debug.profileend()
			end
		else
			if collectStats then stats.deferSeconds = 0 end
			screen.Visible = false
			text.Text = "VGA display requires EditableImage."
			displayedVersion, displayedRegisters = -1, -1
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
	local deviceSeconds = os.clock() - devicesStartedAt
	if runCpu and not debugger.paused then frameBudget:endFrame(clocks, cpuSeconds, deviceSeconds) end
	if debugger.group.Visible and os.clock() - lastDebugRefresh >= 0.25 then
		lastDebugRefresh = os.clock()
		debugger:refresh()
	end
	if collectStats then
		stats:sample(elapsed, clocks, cpuSeconds, budget, frameBudget.saturated, audioSeconds, machine.board, presented, deviceSeconds, audioOutput)
	end
end)

gui.Destroying:Connect(function()
	sizeConnection:Disconnect()
	statsVisibilityConnection:Disconnect()
	debugVisibilityConnection:Disconnect()
	debugger:detach()
	renderStatsConnection:Disconnect()
	stats:detachDisks()
	if stats.cpu then
		stats.cpu.opcodeTrace = false
	end
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
