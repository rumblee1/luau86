local StatsOverlay = {}
StatsOverlay.__index = StatsOverlay

local band = bit32.band
local format = string.format
local UI_FONT = Font.fromEnum(Enum.Font.BuilderSans)
local HEADER_FONT = Font.fromEnum(Enum.Font.BuilderSansMedium)
local MONO_FONT = Font.fromEnum(Enum.Font.RobotoMono)
local SAMPLE_SECONDS = 0.5
local ROW_HEIGHT = 22
local HEADER_HEIGHT = 24
local SECTION_GAP = 4
local TABS = { "CPU", "Registers", "Devices" }
local SECTIONS = {
	{
		{ "Execution", "Mode", "Code size", "Status", "CPL", "Paging", "CS:EIP", "IRQ pending", "Halted frames", "Halted sampled time" },
		{ "Performance", "Host FPS", "Frame time (P95)", "CPU time (P95)", "CPU budget", "Budget used (P95)", "Guest clock", "CPU-limited", "Budget overruns" },
		{ "Instruction tracing", "Trace", "Last instruction", "Prefixes", "Last fault", "Decoded per second" },
		{ "Opcode frequency", "Most frequent", "Second", "Third" },
	},
	{
		{ "General registers", "EAX / EBX", "ECX / EDX", "ESI / EDI", "ESP / EBP" },
		{ "Segment registers", "CS", "DS / ES / SS", "FS / GS" },
		{ "System registers", "CR0 / CR3", "CR2", "CR4", "GDTR base / limit", "IDTR base / limit", "A20" },
		{ "Flags", "EFLAGS", "CF / PF / AF", "ZF / SF / TF", "IF / DF / OF", "IOPL / NT / VM" },
	},
	{
		{ "Display", "VGA mode", "VGA convert / upload", "VGA updates per second", "VGA deferred frames", "VGA defer current", "VGA defer streak (P95)" },
		{ "Memory and storage", "Guest RAM", "IDE sectors read", "IDE sectors written", "IDE reads / sec", "IDE writes / sec" },
		{ "Interrupts and timers", "PIC pending", "PIT clocks" },
		{ "Audio and input", "Audio processing", "Audio underruns", "Writer underruns", "Keyboard queue", "Mouse reports queued", "Mouse bytes queued", "Mouse to display" },
		{ "Host processing", "Host devices (P95)" },
	},
}
local MONO = {
	["CS:EIP"] = true, ["Last instruction"] = true, Prefixes = true, ["Last fault"] = true,
	["Most frequent"] = true, Second = true, Third = true,
	["EAX / EBX"] = true, ["ECX / EDX"] = true, ["ESI / EDI"] = true, ["ESP / EBP"] = true,
	["DS / ES / SS"] = true, EFLAGS = true, ["CR0 / CR3"] = true, ["PIC pending"] = true,
	CS = true, ["FS / GS"] = true, CR2 = true, CR4 = true,
	["GDTR base / limit"] = true, ["IDTR base / limit"] = true,
	["CF / PF / AF"] = true, ["ZF / SF / TF"] = true, ["IF / DF / OF"] = true, ["IOPL / NT / VM"] = true,
}
local CAPTIONS = {
	["VGA convert / upload"] = "VGA conv / upload (P95)",
	["Audio processing"] = "Audio (P95)",
	["Mouse to display"] = "Mouse to display (P95)",
	["Decoded per second"] = "Decoded / sec",
	["VGA updates per second"] = "VGA updates / sec",
	["VGA deferred frames"] = "VGA deferred (%)",
	["VGA defer streak (P95)"] = "VGA defer (P95)",
	["Halted frames"] = "HLT frame-end (%)",
	["Halted sampled time"] = "HLT sampled time",
	["VGA defer current"] = "VGA defer (current)",
	["IRQ pending"] = "IRQ pending (raw)",
	["CPU budget"] = "CPU budget (latest)",
	["IDE sectors read"] = "IDE reads (session)",
	["IDE sectors written"] = "IDE writes (session)",
	["IDE reads / sec"] = "IDE read sectors/s",
	["IDE writes / sec"] = "IDE write sectors/s",
	["Mouse reports queued"] = "Mouse reports",
	["Mouse bytes queued"] = "Mouse bytes",
}

local function percentile(samples)
	if #samples == 0 then
		return nil
	end
	table.sort(samples)
	return samples[math.ceil(#samples * 0.95)]
end

function StatsOverlay.new(parent, style)
	local background, foreground = style.BackgroundColor3, style.TextColor3
	local muted = foreground:Lerp(background, 0.30)
	local headerColor = background:Lerp(foreground, 0.08)
	local activeColor = background:Lerp(foreground, 0.17)
	local barColor = foreground:Lerp(background, 0.30)

	local group = Instance.new("Frame")
	group.Name = "Stats"
	group.AnchorPoint = Vector2.zero
	group.BackgroundColor3 = background
	group.BorderSizePixel = 0
	group.Active = true
	group.Visible = false
	group.ClipsDescendants = true
	group.ZIndex = 2

	local function label(parent, caption, color, mono)
		local text = Instance.new("TextLabel")
		text.BackgroundTransparency = 1
		text.TextColor3 = color
		text.FontFace = if mono then MONO_FONT else UI_FONT
		text.TextSize = 13
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.Text = caption
		text.ZIndex = 3
		text.Parent = parent
		return text
	end

	local function button(parent, caption)
		local item = Instance.new("TextButton")
		item.BackgroundColor3 = headerColor
		item.BorderSizePixel = 0
		item.TextColor3 = foreground
		item.FontFace = HEADER_FONT
		item.TextSize = 13
		item.Text = caption
		item.ZIndex = 3
		item.Parent = parent
		return item
	end

	local title = label(group, "Machine details", foreground, false)
	title.FontFace = HEADER_FONT
	title.TextSize = 14
	title.Position = UDim2.fromOffset(8, 0)
	title.Size = UDim2.new(1, -42, 0, 28)
	local close = button(group, "×")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -4, 0, 3)
	close.Size = UDim2.fromOffset(24, 22)
	close.BackgroundTransparency = 1

	local tabs = {}
	for index, name in TABS do
		local tab = button(group, name)
		tab.Name = name
		tab.Position = UDim2.new((index - 1) / #TABS, 2, 0, 28)
		tab.Size = UDim2.new(1 / #TABS, -4, 0, 26)
		tabs[index] = tab
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Content"
	scroll.Position = UDim2.fromOffset(0, 58)
	scroll.Size = UDim2.new(1, 0, 1, -58)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Active = true
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = muted
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.ZIndex = 2
	scroll.Parent = group

	local values, bars, pages = {}, {}, {}
	local traceButton
	local overlay
	local selected = 1

	local function reflow()
		local y = 0
		for _, section in pages[selected] do
			section.container.Position = UDim2.fromOffset(0, y)
			local height = HEADER_HEIGHT
			for _, row in section.rows do
				row.Visible = section.expanded
				if section.expanded then
					row.Position = UDim2.fromOffset(0, height)
					height += row.Size.Y.Offset
				end
			end
			section.container.Size = UDim2.new(1, 0, 0, height)
			section.header.Text = (if section.expanded then "  −  " else "  +  ") .. section.name
			y += height + SECTION_GAP
		end
		local height = math.max(0, y - SECTION_GAP)
		scroll.CanvasSize = UDim2.fromOffset(0, height)
		local maxScroll = math.max(0, height - scroll.AbsoluteWindowSize.Y)
		scroll.CanvasPosition = Vector2.new(0, math.min(scroll.CanvasPosition.Y, maxScroll))
	end

	for pageIndex, definitions in SECTIONS do
		local sections = {}
		pages[pageIndex] = sections
		for _, definition in definitions do
			local container = Instance.new("Frame")
			container.Name = definition[1]
			container.BackgroundTransparency = 1
			container.ClipsDescendants = true
			container.Visible = false
			container.ZIndex = 2
			container.Parent = scroll

			local header = button(container, definition[1])
			header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
			header.TextXAlignment = Enum.TextXAlignment.Left
			local section = {
				name = definition[1], container = container, header = header, rows = {},
				expanded = definition[1] == "Execution" or definition[1] == "Performance"
					or definition[1] == "General registers" or definition[1] == "Display",
			}
			sections[#sections + 1] = section
			header.Activated:Connect(function()
				section.expanded = not section.expanded
				reflow()
			end)

			for index = 2, #definition do
				local name = definition[index]
				local hasBar = name == "Budget used (P95)" or name == "Guest clock"
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT + (if hasBar then 8 else 0))
				row.BackgroundTransparency = 1
				row.ZIndex = 2
				row.Parent = container
				section.rows[#section.rows + 1] = row

				local caption = label(row, CAPTIONS[name] or name, muted, false)
				caption.Position = UDim2.fromOffset(8, 0)
				caption.Size = UDim2.new(0.44, -10, 0, ROW_HEIGHT)
				local value
				if name == "Trace" then
					value = button(row, "Off")
					traceButton = value
					value.Activated:Connect(function()
						if overlay then
							overlay:setTracing(not overlay.traceEnabled)
						end
					end)
				else
					value = label(row, "—", foreground, MONO[name])
				end
				value.Position = UDim2.new(0.44, 2, 0, 0)
				value.Size = UDim2.new(0.56, -10, 0, ROW_HEIGHT)
				value.TextXAlignment = if name == "Trace" then Enum.TextXAlignment.Center else Enum.TextXAlignment.Right
				values[name] = value

				if hasBar then
					local track = Instance.new("Frame")
					track.Position = UDim2.fromOffset(8, ROW_HEIGHT)
					track.Size = UDim2.new(1, -16, 0, 4)
					track.BackgroundColor3 = activeColor
					track.BorderSizePixel = 0
					track.ZIndex = 3
					track.Parent = row
					local fill = Instance.new("Frame")
					fill.Size = UDim2.fromScale(0, 1)
					fill.BackgroundColor3 = barColor
					fill.BorderSizePixel = 0
					fill.ZIndex = 4
					fill.Parent = track
					bars[name] = fill
				end
			end
		end
	end

	local function selectTab(index)
		selected = index
		for pageIndex, sections in pages do
			tabs[pageIndex].BackgroundColor3 = if pageIndex == selected then activeColor else headerColor
			for _, section in sections do
				section.container.Visible = pageIndex == selected
			end
		end
		scroll.CanvasPosition = Vector2.zero
		reflow()
	end
	for index, tab in tabs do
		tab.Activated:Connect(function()
			selectTab(index)
		end)
	end
	selectTab(1)
	group.Parent = parent

	overlay = setmetatable({
		group = group, close = close, values = values, bars = bars,
		traceButton = traceButton, traceEnabled = false,
		cpuMs = {}, budgetUse = {}, audio = {}, convert = {}, upload = {}, mouse = {},
		frameMs = {}, deviceMs = {}, deferMs = {}, diskHooks = {}, diskPrevious = {}, diskTotals = {},
	}, StatsOverlay)
	return overlay
end

function StatsOverlay:clearSamples()
	table.clear(self.cpuMs)
	table.clear(self.budgetUse)
	table.clear(self.audio)
	table.clear(self.convert)
	table.clear(self.upload)
	table.clear(self.mouse)
	table.clear(self.frameMs)
	table.clear(self.deviceMs)
	table.clear(self.deferMs)
	self.elapsed, self.clocks, self.limited, self.updates = 0, 0, 0, 0
	self.overruns, self.haltedFrames, self.vgaFrames, self.deferredFrames = 0, 0, 0, 0
	self.renderElapsed, self.haltedElapsed = 0, 0
end

-- Only attach the trace to the CPU when explicitly requested.
function StatsOverlay:setTracing(enabled)
	self.traceEnabled = enabled
	if self.cpu then
		self.cpu.opcodeTrace = false
	end
	self.trace = nil
	self.traceButton.Text = if enabled then "On" else "Off"
	for _, name in { "Last instruction", "Prefixes", "Last fault", "Decoded per second", "Most frequent", "Second", "Third" } do
		self.values[name].Text = if enabled then "—" else "Off"
	end
	if enabled and self.cpu and self.group.Visible then
		self.trace = { counts = {}, prefixes = {}, decoded = 0 }
		self.traceStartedAt = os.clock()
		self.cpu.opcodeTrace = self.trace
	end
end

-- Restore original disk dispatch when closing the inspector or changing machines.
function StatsOverlay:detachDisks()
	for disk, hook in self.diskHooks do
		if rawget(disk, "advanceData") == hook.wrapper then
			disk.advanceData = hook.previous
		end
	end
	table.clear(self.diskHooks)
	table.clear(self.diskPrevious)
	table.clear(self.diskTotals)
	self.diskBoard = nil
end

-- For versions without native sector counters, count completed image sectors
-- through the ATA advanceData method, only while the inspector is active.
function StatsOverlay:attachDisks(board)
	if self.diskBoard == board then return end
	self:detachDisks()
	self.diskBoard = board
	for _, disk in { board.hardDisk or false, board.secondHardDisk or false } do
		if type(disk) == "table" and not table.isfrozen(disk)
			and type(disk.advanceData) == "function" and typeof(disk.image) == "buffer"
			and (type(disk.sectorsRead) ~= "number" or type(disk.sectorsWritten) ~= "number") then
			local original = disk.advanceData
			local hook = { previous = rawget(disk, "advanceData"), reads = 0, writes = 0 }
			hook.wrapper = function(device, size, ...)
				local cursor, writing = device.cursor, device.writing
				local imageTransfer = device.transfer == device.image
				local result = original(device, size, ...)
				if imageTransfer and type(cursor) == "number" and type(device.cursor) == "number" then
					local sectors = math.max(0, math.floor(device.cursor / 512) - math.floor(cursor / 512))
					if writing then hook.writes += sectors else hook.reads += sectors end
				end
				return result
			end
			disk.advanceData = hook.wrapper
			self.diskHooks[disk] = hook
		end
	end
	for _, disk in { board.hardDisk or false, board.secondHardDisk or false } do
		if disk then
			local reads, writes = self:diskCounts(disk)
			self.diskPrevious[disk] = { reads = reads, writes = writes }
			self.diskTotals[disk] = { reads = if reads ~= nil then 0 else nil, writes = if writes ~= nil then 0 else nil }
		end
	end
end

function StatsOverlay:diskCounts(disk)
	if not disk then return nil, nil end
	local hook = self.diskHooks[disk]
	local reads = if type(disk.sectorsRead) == "number" then disk.sectorsRead else hook and hook.reads
	local writes = if type(disk.sectorsWritten) == "number" then disk.sectorsWritten else hook and hook.writes
	return reads, writes
end

function StatsOverlay:reset(cpu, status)
	if self.cpu then
		self.cpu.opcodeTrace = false
	end
	self:detachDisks()
	self.diskBoard = nil
	self.cpu, self.trace = nil, nil
	self.deferSeconds = 0
	self:clearSamples()
	for _, bar in self.bars do
		bar.Size = UDim2.fromScale(0, 1)
	end
	self.startedAt = os.clock()
	self.lastMouseReport, self.pendingMouseAt = nil, nil
	if not self.group.Visible then
		return
	end
	for _, value in self.values do
		value.Text = "—"
	end
	self.values.Status.Text = status or "Measuring…"
	self.cpu = cpu
	self:setTracing(self.traceEnabled)
end

function StatsOverlay:toggle(cpu, status)
	self.group.Visible = not self.group.Visible
	self:reset(cpu, status)
end

function StatsOverlay:contains(position)
	local group = self.group
	if not group.Visible then
		return false
	end
	local origin, size = group.AbsolutePosition, group.AbsoluteSize
	return position.X >= origin.X
		and position.Y >= origin.Y
		and position.X < origin.X + size.X
		and position.Y < origin.Y + size.Y
end

function StatsOverlay:recordVga(convertSeconds, uploadSeconds)
	table.insert(self.convert, convertSeconds * 1000)
	table.insert(self.upload, uploadSeconds * 1000)
	self.updates += 1
end

local function opcodeText(opcode)
	return if opcode < 256 then format("%02X", opcode) else format("0F %02X", opcode - 256)
end

function StatsOverlay:showCpu()
	local values, trace, cpu = self.values, self.trace, self.cpu
	local cr0 = cpu.control and cpu.control[0] or 0
	local mode = if band(cpu.flags, 0x20000) ~= 0
		then "Virtual 8086"
		elseif band(cr0, 1) ~= 0 then "Protected"
		else "Real"
	values.Mode.Text = mode
	values["Code size"].Text = if cpu.codeMask == 0xFFFF then "16-bit" else "32-bit"
	values.Status.Text = if cpu.halted then "HLT" else "Running"
	values["CS:EIP"].Text = format("%04X:%08X", cpu:selector(2), cpu.ip)
	if trace then
		if trace.opcode then
			values["Last instruction"].Text = format("%04X:%08X · %s", trace.cs, trace.ip, opcodeText(trace.opcode))
			local prefixes = table.create(trace.prefixCount)
			for index = 1, trace.prefixCount do
				prefixes[index] = format("%02X", trace.prefixes[index])
			end
			values.Prefixes.Text = if #prefixes == 0 then "None" else table.concat(prefixes, " ")
		end
		if trace.faultVector then
			values["Last fault"].Text = format("#%d at %04X:%08X", trace.faultVector, trace.faultCS, trace.faultIP)
		end
		local traceSeconds = math.max(0.001, os.clock() - self.traceStartedAt)
		values["Decoded per second"].Text = format("%.0f", trace.decoded / traceSeconds)
		self.traceStartedAt = os.clock()

		local common = {}
		for opcode, count in trace.counts do
			table.insert(common, { opcode, count })
		end
		table.sort(common, function(a, b)
			return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1])
		end)
		for index, name in { "Most frequent", "Second", "Third" } do
			local entry = common[index]
			values[name].Text = if entry then format("%s · %d", opcodeText(entry[1]), entry[2]) else "—"
		end
		table.clear(trace.counts)
		trace.decoded = 0
	end

	local r = cpu.r
	values["EAX / EBX"].Text = format("%08X / %08X", r[1], r[4])
	values["ECX / EDX"].Text = format("%08X / %08X", r[2], r[3])
	values["ESI / EDI"].Text = format("%08X / %08X", r[7], r[8])
	values["ESP / EBP"].Text = format("%08X / %08X", r[5], r[6])
	values["DS / ES / SS"].Text = format("%04X / %04X / %04X", cpu:selector(4), cpu:selector(1), cpu:selector(3))
	values.EFLAGS.Text = format("%08X", cpu.flags)
	values["CR0 / CR3"].Text = if cpu.control then format("%08X / %08X", cr0, cpu.control[3]) else "—"
	values.CPL.Text = if mode == "Virtual 8086" then "3" elseif mode == "Real" then "N/A" elseif type(cpu.cpl) == "number" then format("%d", cpu.cpl) else "—"
	values.Paging.Text = if cpu.control then (if band(cr0, 0x80000000) ~= 0 then "On" else "Off") else "N/A"
	values.CS.Text = format("%04X", cpu:selector(2))
	values["FS / GS"].Text = if cpu.is386 and cpu.s and cpu.s[5] and cpu.s[6]
		then format("%04X / %04X", cpu:selector(5), cpu:selector(6)) else "N/A"
	for _, index in { 2, 4 } do
		local value = cpu.control and cpu.control[index]
		values["CR" .. index].Text = if type(value) == "number" then format("%08X", value) else "N/A"
	end
	for _, item in { { "GDTR base / limit", cpu.gdt }, { "IDTR base / limit", cpu.idt } } do
		local descriptor = item[2]
		values[item[1]].Text = if type(descriptor) == "table" and type(descriptor.base) == "number" and type(descriptor.limit) == "number"
			then format("%08X / %04X", descriptor.base, descriptor.limit) else "N/A"
	end
	local function flag(mask) return if band(cpu.flags, mask) ~= 0 then 1 else 0 end
	values["CF / PF / AF"].Text = format("%d / %d / %d", flag(1), flag(4), flag(16))
	values["ZF / SF / TF"].Text = format("%d / %d / %d", flag(64), flag(128), flag(256))
	values["IF / DF / OF"].Text = format("%d / %d / %d", flag(512), flag(1024), flag(2048))
	values["IOPL / NT / VM"].Text = if cpu.is386 then format("%d / %d / %d", bit32.extract(cpu.flags, 12, 2), flag(0x4000), flag(0x20000)) else "N/A"
end

function StatsOverlay:recordRender(elapsed)
	if self.cpu and self.group.Visible and elapsed > 0 then
		self.renderElapsed += elapsed
		table.insert(self.frameMs, elapsed * 1000)
	end
end

function StatsOverlay:recordPresentation(elapsed, deferred)
	self.vgaFrames += 1
	if deferred then
		self.deferredFrames += 1
		self.deferSeconds += elapsed
	elseif self.deferSeconds > 0 then
		table.insert(self.deferMs, self.deferSeconds * 1000)
		self.deferSeconds = 0
	end
end

local function numberText(value)
	return if type(value) == "number" then format("%d", value) else "—"
end

local function pairText(a, b)
	return numberText(a) .. " / " .. numberText(b)
end

function StatsOverlay:sample(elapsed, clocks, cpuSeconds, budget, cpuLimited, audioSeconds, board, presented, deviceSeconds, audioOutput)
	if not self.cpu then
		return
	end
	self.elapsed += elapsed
	self.clocks += clocks
	self.limited += if cpuLimited then 1 else 0
	self.haltedFrames += if self.cpu.halted then 1 else 0
	-- Frame-end sampling, not instruction-accurate guest HLT residency.
	self.haltedElapsed += if self.cpu.halted then elapsed else 0
	if deviceSeconds then table.insert(self.deviceMs, deviceSeconds * 1000) end
	table.insert(self.cpuMs, cpuSeconds * 1000)
	if budget > 0 then
		table.insert(self.budgetUse, cpuSeconds / budget)
		self.overruns += if cpuSeconds > budget then 1 else 0
	end
	if audioSeconds then table.insert(self.audio, audioSeconds * 1000) end

	local mouse = board.serialMouse
	if
		mouse
		and mouse.lastMotionReadAt
		and mouse.lastMotionReadAt >= self.startedAt
		and (mouse.motionReports or mouse.lastMotionReadAt) ~= self.lastMouseReport
	then
		self.lastMouseReport = mouse.motionReports or mouse.lastMotionReadAt
		self.pendingMouseAt = mouse.lastMotionReadAt
	end
	if presented and self.pendingMouseAt then
		table.insert(self.mouse, (os.clock() - self.pendingMouseAt) * 1000)
		self.pendingMouseAt = nil
	end
	if self.elapsed < SAMPLE_SECONDS then
		return
	end

	self:showCpu()
	local values = self.values
	values["CPU time (P95)"].Text = format("%.1f ms", percentile(self.cpuMs))
	values["CPU budget"].Text = format("%.1f ms", budget * 1000)
	local budgetUse = percentile(self.budgetUse)
	values["Budget used (P95)"].Text = if budgetUse then format("%.0f%%", budgetUse * 100) else "—"
	self.bars["Budget used (P95)"].Size = UDim2.fromScale(math.clamp(budgetUse or 0, 0, 1), 1)
	local guestClock = self.clocks / (self.elapsed * board.clockRate)
	values["Guest clock"].Text = format("%.0f%%", guestClock * 100)
	self.bars["Guest clock"].Size = UDim2.fromScale(math.clamp(guestClock, 0, 1), 1)
	values["CPU-limited"].Text = format("%.0f%%", 100 * self.limited / #self.cpuMs)
	values["Budget overruns"].Text = if #self.budgetUse > 0 then format("%.0f%%", 100 * self.overruns / #self.budgetUse) else "—"
	values["Halted frames"].Text = format("%.0f%%", 100 * self.haltedFrames / #self.cpuMs)
	values["Halted sampled time"].Text = format("%.0f%%", 100 * self.haltedElapsed / self.elapsed)
	values["Host FPS"].Text = if self.renderElapsed > 0 then format("%.1f", #self.frameMs / self.renderElapsed) else "—"
	local frameP95, deviceP95 = percentile(self.frameMs), percentile(self.deviceMs)
	values["Frame time (P95)"].Text = if frameP95 then format("%.1f ms", frameP95) else "—"
	values["Host devices (P95)"].Text = if deviceP95 then format("%.1f ms", deviceP95) else "—"
	local master, slave = board.pic.pending, board.slavePic and board.slavePic.pending or 0
	local irq = {}
	for i = 0, 7 do
		if band(master, bit32.lshift(1, i)) ~= 0 then irq[#irq + 1] = tostring(i) end
		if band(slave, bit32.lshift(1, i)) ~= 0 then irq[#irq + 1] = tostring(i + 8) end
	end
	values["IRQ pending"].Text = if #irq > 0 then table.concat(irq, ", ") else "None"
	local bus = board.bus
	values.A20.Text = if bus.at and type(bus.a20) == "boolean" then (if bus.a20 then "On" else "Off") else "N/A"
	if type(bus.ramKiB) == "function" then
		local conventional, extended = bus:ramKiB()
		values["Guest RAM"].Text = format("%.2f MiB", (conventional + extended) / 1024)
	else
		values["Guest RAM"].Text = "—"
	end
	local vga = board.bus.vga
	values["VGA mode"].Text = if vga and vga.active
		then format("%d×%d · %s", vga.width, vga.height, if vga.indexed then "indexed" else "planar")
		else "Text"
	values["VGA convert / upload"].Text = if #self.convert > 0
		then format("%.1f / %.1f ms", percentile(self.convert), percentile(self.upload))
		else "—"
	values["VGA updates per second"].Text = format("%.0f", self.updates / self.elapsed)
	values["VGA deferred frames"].Text = if self.vgaFrames > 0 then format("%.0f%%", 100 * self.deferredFrames / self.vgaFrames) else "—"
	values["VGA defer current"].Text = if self.vgaFrames > 0 then format("%.1f ms", self.deferSeconds * 1000) else "—"
	local deferP95 = percentile(self.deferMs)
	values["VGA defer streak (P95)"].Text = if deferP95 then format("%.1f ms", deferP95) else "—"
	local primary, secondary = board.hardDisk, board.secondHardDisk
	local readRate, writeRate = 0, 0
	local diskCount, readsKnown, writesKnown = 0, 0, 0
	for _, disk in { primary or false, secondary or false } do
		if disk then
			diskCount += 1
			local reads, writes = self:diskCounts(disk)
			local prev = self.diskPrevious[disk] or {}
			local totals = self.diskTotals[disk] or {}
			if type(reads) == "number" and type(prev.reads) == "number" and reads >= prev.reads then
				local delta = reads - prev.reads
				readRate += delta / self.elapsed
				totals.reads = (totals.reads or 0) + delta
				readsKnown += 1
			end
			if type(writes) == "number" and type(prev.writes) == "number" and writes >= prev.writes then
				local delta = writes - prev.writes
				writeRate += delta / self.elapsed
				totals.writes = (totals.writes or 0) + delta
				writesKnown += 1
			end
			self.diskPrevious[disk] = { reads = reads, writes = writes }
			self.diskTotals[disk] = totals
		end
	end
	local totals1 = primary and self.diskTotals[primary] or {}
	local totals2 = secondary and self.diskTotals[secondary] or {}
	values["IDE sectors read"].Text = pairText(totals1.reads, totals2.reads)
	values["IDE sectors written"].Text = pairText(totals1.writes, totals2.writes)
	values["IDE reads / sec"].Text = if diskCount > 0 and readsKnown == diskCount then format("%.1f", readRate) else "—"
	values["IDE writes / sec"].Text = if diskCount > 0 and writesKnown == diskCount then format("%.1f", writeRate) else "—"
	values["Keyboard queue"].Text = if type(board.keyboard) == "table" then format("%d", #board.keyboard + (if board.scanCode ~= nil then 1 else 0)) else "—"
	values["Mouse reports queued"].Text = if mouse and type(mouse.pending) == "table" then numberText(#mouse.pending) else "—"
	values["Mouse bytes queued"].Text = if mouse and type(mouse.bytes) == "table" then numberText(#mouse.bytes + (if mouse.received ~= nil then 1 else 0)) else "—"
	values["Audio underruns"].Text = numberText(audioOutput and audioOutput.queue and audioOutput.queue.underruns)
	values["Writer underruns"].Text = numberText(audioOutput and audioOutput.writer and audioOutput.writerUnderruns)
	values["PIC pending"].Text =
		format("%02X / %02X", board.pic.pending, board.slavePic and board.slavePic.pending or 0)
	values["PIT clocks"].Text = format("%d", board.pit.now)
	local audioP95 = percentile(self.audio)
	values["Audio processing"].Text = if audioP95 then format("%.1f ms", audioP95) else "—"
	local mouseMs = percentile(self.mouse)
	values["Mouse to display"].Text = if mouseMs then format("%.0f ms", mouseMs) else "—"
	self:clearSamples()
end

return StatsOverlay
