-- Optional, local guest-machine debugger. No host memory or host process access.
local Debugger = {}
Debugger.__index = Debugger

local band, rshift = bit32.band, bit32.rshift
local fmt = string.format
local MONO = Font.fromEnum(Enum.Font.RobotoMono)
local FONT = Font.fromEnum(Enum.Font.BuilderSans)
local MEDIUM = Font.fromEnum(Enum.Font.BuilderSansMedium)

local ROW_HEIGHT, HEADER_HEIGHT, SECTION_GAP = 22, 24, 4
local DUMP_BYTES_PER_ROW = 16
local DUMP_ROWS = 8

local function hex(n, width)
	return if type(n) == "number" then fmt("%0" .. (width or 8) .. "X", n) else "—"
end

local function parseHex(s)
	s = s:match("^%s*(.-)%s*$"):gsub("^0[xX]", "")
	if not s:match("^%x+$") or #s > 8 then
		return nil
	end
	return tonumber(s, 16)
end

local function make(parent, class, props)
	local obj = Instance.new(class)
	for k, v in props do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function address(cpu)
	return fmt("%04X:%08X", cpu:selector(2), cpu.ip)
end

local function cpuMode(cpu)
	local cr0 = cpu.control and cpu.control[0] or 0
	if band(cpu.flags, 0x20000) ~= 0 then
		return "Virtual 8086"
	elseif band(cr0, 1) ~= 0 then
		return "Protected"
	end
	return "Real"
end

local function privilege(cpu)
	local cs = cpu.s and cpu.s[2]
	if type(cs) == "table" and type(cs.selector) == "number" then
		return tostring(band(rshift(cs.selector, 0), 3))
	end
	return "0"
end

local function flagString(flags)
	local names = {
		{"CF", 0x0001}, {"PF", 0x0004}, {"AF", 0x0010}, {"ZF", 0x0040},
		{"SF", 0x0080}, {"TF", 0x0100}, {"IF", 0x0200}, {"DF", 0x0400},
		{"OF", 0x0800}, {"NT", 0x4000}, {"RF", 0x10000}, {"VM", 0x20000},
	}
	local out = table.create(#names)
	for _, item in names do
		out[#out + 1] = item[1] .. "=" .. (if band(flags, item[2]) ~= 0 then "1" else "0")
	end
	return table.concat(out, " ")
end

local function segBase(seg)
	if type(seg) == "table" then
		return seg.base
	elseif type(seg) == "number" then
		return seg * 16
	end
	return nil
end

local function peek(bus, a)
	local vga = bus.vga
	local latch = vga and vga.latches
	local ok, value = pcall(bus.read8, bus, band(a, 0xFFFFFFFF))
	if vga then
		vga.latches = latch
	end
	return if ok then value else nil
end

local function dword(bus, a)
	local value = 0
	for i = 0, 3 do
		local byte = peek(bus, a + i)
		if byte == nil then
			return nil
		end
		value += byte * 256 ^ i
	end
	return value
end

local function walk(cpu, bus, linear)
	local c = cpu.control
	if not c or band(c[0], 0x80000000) == 0 then
		return linear, nil, nil, "Paging off"
	end
	local pda = band(c[3], 0xFFFFF000) + rshift(linear, 22) * 4
	local pde = dword(bus, pda)
	if not pde or band(pde, 1) == 0 then
		return nil, pde, nil, "PDE not present"
	end
	local pta = band(pde, 0xFFFFF000) + band(rshift(linear, 12), 1023) * 4
	local pte = dword(bus, pta)
	if not pte or band(pte, 1) == 0 then
		return nil, pde, pte, "PTE not present"
	end
	local perm = band(pde, pte)
	return band(pte, 0xFFFFF000) + band(linear, 4095), pde, pte,
		(if band(perm, 4) ~= 0 then "User" else "Supervisor") .. " / " .. (if band(perm, 2) ~= 0 then "R/W" else "Read-only")
end

local function codeByte(cpu, bus, offset)
	local cs = cpu.s[2]
	local ip = band(cpu.ip + offset, cpu.codeMask)
	local base = segBase(cs)
	if not base then
		return nil
	end
	if type(cs) == "table" and ip > cs.limit then
		return nil
	end
	local phys = walk(cpu, bus, band(base + ip, 0xFFFFFFFF))
	return if phys then peek(bus, phys) else nil
end

local simple = {
	[0x90] = "NOP", [0xF4] = "HLT", [0xFA] = "CLI", [0xFB] = "STI", [0xFC] = "CLD",
	[0xFD] = "STD", [0xC3] = "RET", [0xCB] = "RETF", [0xCF] = "IRET", [0xCC] = "INT3",
	[0x9C] = "PUSHF", [0x9D] = "POPF", [0xC9] = "LEAVE", [0xF8] = "CLC", [0xF9] = "STC", [0xF5] = "CMC",
}
local regs16 = {"AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI"}
local regs32 = {"EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"}
local regs8 = {"AL", "CL", "DL", "BL", "AH", "CH", "DH", "BH"}
local prefixNames = {
	[0x26] = "ES:", [0x2E] = "CS:", [0x36] = "SS:", [0x3E] = "DS:", [0x64] = "FS:", [0x65] = "GS:",
	[0x66] = "O-size", [0x67] = "A-size", [0xF0] = "LOCK", [0xF2] = "REPNE", [0xF3] = "REP",
}
local conditions = {"JO", "JNO", "JB", "JAE", "JE", "JNE", "JBE", "JA", "JS", "JNS", "JP", "JNP", "JL", "JGE", "JLE", "JG"}

local function decode(cpu, bus)
	local bytes = {}
	for i = 0, 14 do
		local b = codeByte(cpu, bus, i)
		if b == nil then
			break
		end
		bytes[#bytes + 1] = b
	end
	local index, prefixes, override = 1, {}, false
	while bytes[index] and prefixNames[bytes[index]] and index < 15 do
		local b = bytes[index]
		if b >= 0x64 and b <= 0x67 and not cpu.is386 then
			break
		end
		if b == 0x66 then
			override = true
		end
		prefixes[#prefixes + 1] = prefixNames[b]
		index += 1
	end
	local op = bytes[index]
	local wide = (cpu.codeMask == 0xFFFFFFFF) ~= override
	local regs = if wide then regs32 else regs16
	local size = if wide then 4 else 2
	local function imm(n)
		local v = 0
		for i = 1, n do
			local b = bytes[index + i]
			if not b then
				return nil
			end
			v += b * 256 ^ (i - 1)
		end
		return v
	end
	local mnemonic, length = op and simple[op], index
	if op == 0xC9 and not cpu.is386 then
		mnemonic = nil
	end
	if op and op >= 0xB0 and op <= 0xBF then
		local n = if op < 0xB8 then 1 else size
		local v = imm(n)
		if v then
			mnemonic = "MOV " .. (if n == 1 then regs8[op - 0xB0 + 1] else regs[op - 0xB8 + 1]) .. ", 0x" .. hex(v, n * 2)
			length = index + n
		end
	elseif op and op >= 0x50 and op <= 0x5F then
		mnemonic = (if op < 0x58 then "PUSH " else "POP ") .. regs[band(op, 7) + 1]
	elseif op and op >= 0x40 and op <= 0x4F then
		mnemonic = (if op < 0x48 then "INC " else "DEC ") .. regs[band(op, 7) + 1]
	elseif op == 0xCD then
		local v = imm(1)
		if v then
			mnemonic = "INT 0x" .. hex(v, 2)
			length = index + 1
		end
	elseif op == 0xE8 or op == 0xE9 or op == 0xEB or (op and op >= 0x70 and op <= 0x7F) then
		local n = if op == 0xE8 or op == 0xE9 then size else 1
		local v = imm(n)
		if v then
			if v >= 2 ^ (n * 8 - 1) then
				v -= 2 ^ (n * 8)
			end
			local dest = band(cpu.ip + index + n + v, cpu.codeMask)
			mnemonic = (if op == 0xE8 then "CALL" elseif op == 0xE9 or op == 0xEB then "JMP" else conditions[op - 0x70 + 1]) .. " 0x" .. hex(dest, if wide then 8 else 4)
			length = index + n
		end
	end
	local raw = {}
	for i = 1, (if mnemonic then length else #bytes) do
		raw[#raw + 1] = hex(bytes[i], 2)
	end
	return table.concat(raw, " "), (if #prefixes > 0 then table.concat(prefixes, " ") .. " " else "") .. (mnemonic or "Undecoded — raw bytes only")
end

local function registerRows(buf)
	local rows = {}
	if typeof(buf) ~= "buffer" then
		return {{"Status", "Unavailable", nil, true}}
	end
	for start = 0, buffer.len(buf) - 1, 8 do
		local vals = {}
		for i = start, math.min(start + 7, buffer.len(buf) - 1) do
			vals[#vals + 1] = hex(buffer.readu8(buf, i), 2)
		end
		rows[#rows + 1] = {hex(start, 2), table.concat(vals, " "), 30}
	end
	return rows
end

local function regionName(bus, addressValue)
	local physical = bus:physical(addressValue)
	local conventional = bus.CONVENTIONAL_BYTES or 0
	if physical < conventional then
		return "Conventional RAM"
	elseif bus.at and physical >= 0x100000 and physical < buffer.len(bus.memory) then
		return "Extended RAM"
	elseif bus.vga and physical >= 0xA0000 and physical < 0xC0000 then
		return "Video memory"
	elseif physical >= 0xC0000 and physical < 0x100000 then
		return "ROM / option ROM"
	end
	return "Mapped bus"
end

local function stackRows(cpu, bus)
	local rows = {}
	local ss = cpu.s and cpu.s[3]
	local base = segBase(ss)
	if not base then
		return {{"Status", "Unavailable", nil, true}}
	end
	local sp = cpu.r[5]
	local mask = cpu.stackMask or cpu.codeMask or 0xFFFF
	for i = 0, 3 do
		local offset = band(sp + i * 4, mask)
		local linear = band(base + offset, 0xFFFFFFFF)
		local phys = walk(cpu, bus, linear)
		rows[#rows + 1] = {if i == 0 then "ESP" else "+" .. tostring(i * 4), hex(offset, if mask == 0xFFFF then 4 else 8) .. " → " .. hex(dword(bus, phys or linear))}
	end
	return rows
end

function Debugger.new(parent, style)
	local bg, fg = style.BackgroundColor3, style.TextColor3
	local muted = fg:Lerp(bg, 0.30)
	local header = bg:Lerp(fg, 0.08)
	local group = make(parent, "Frame", {
		Name = "Debugger",
		AnchorPoint = Vector2.zero,
		Visible = false,
		BackgroundColor3 = bg,
		BorderSizePixel = 0,
		ZIndex = 2,
		Active = true,
		ClipsDescendants = true,
	})
	local self = setmetatable({
		group = group,
		paused = false,
		stepPending = false,
		breakpoints = {},
		tab = "CPU",
		message = "Open a machine first",
		bg = bg,
		fg = fg,
		muted = muted,
		headerColor = header,
		sections = {},
		visibleSections = {},
		memoryAddress = 0,
	}, Debugger)

	local function text(parent_, class, caption, x, y, w, h)
		return make(parent_, class, {
			Position = UDim2.new(x, 2, 0, y),
			Size = UDim2.new(w, -4, 0, h),
			Text = caption,
			TextColor3 = fg,
			FontFace = if class == "TextButton" then MEDIUM else FONT,
			TextSize = 13,
			BackgroundColor3 = header,
			BackgroundTransparency = if class == "TextLabel" then 1 else 0,
			BorderSizePixel = 0,
			ZIndex = 3,
		})
	end

	local title = text(group, "TextLabel", "Debugger", 0, 0, 1, 28)
	title.Position = UDim2.fromOffset(8, 0)
	title.Size = UDim2.new(1, -42, 0, 28)
	title.FontFace = MEDIUM
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	self.close = text(group, "TextButton", "×", 0, 0, 1, 22)
	self.close.AnchorPoint = Vector2.new(1, 0)
	self.close.Position = UDim2.new(1, -4, 0, 3)
	self.close.Size = UDim2.fromOffset(24, 22)
	self.close.BackgroundTransparency = 1
	self.tabs = {}
	for i, name in {"CPU", "Memory", "Hardware"} do
		local button = text(group, "TextButton", name, (i - 1) / 3, 28, 1 / 3, 26)
		self.tabs[name] = button
		button.Activated:Connect(function()
			self.tab = name
			self:refresh()
		end)
	end
	self.pause = text(group, "TextButton", "Resume", 0, 58, 0.5, 26)
	self.step = text(group, "TextButton", "Step", 0.5, 58, 0.5, 26)
	self.status = text(group, "TextLabel", "", 0, 86, 1, 22)
	self.status.Position = UDim2.fromOffset(8, 86)
	self.status.Size = UDim2.new(1, -16, 0, 22)
	self.status.TextColor3 = muted
	self.status.TextXAlignment = Enum.TextXAlignment.Left

	self.input = text(group, "TextBox", "", 0, 110, 0.65, 26)
	self.input.PlaceholderText = "CS:EIP or current"
	self.input.ClearTextOnFocus = false
	self.input.FontFace = MONO
	self.action = text(group, "TextButton", "Toggle BP", 0.65, 110, 0.35, 26)
	self.value = text(group, "TextBox", "", 0, 140, 0.65, 26)
	self.value.ClearTextOnFocus = false
	self.value.FontFace = MONO
	self.extra = text(group, "TextButton", "Write byte", 0.65, 140, 0.35, 26)
	self.navPrev = text(group, "TextButton", "Prev", 0, 170, 0.25, 24)
	self.navNext = text(group, "TextButton", "Next", 0.25, 170, 0.25, 24)
	self.navIP = text(group, "TextButton", "Jump IP", 0.5, 170, 0.25, 24)
	self.navSP = text(group, "TextButton", "Jump SP", 0.75, 170, 0.25, 24)

	self.scroll = make(group, "ScrollingFrame", {
		Name = "Content",
		Position = UDim2.fromOffset(0, 198),
		Size = UDim2.new(1, 0, 1, -198),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = true,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = muted,
		VerticalScrollBarInset = Enum.ScrollBarInset.Always,
		CanvasSize = UDim2.fromOffset(0, 0),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 2,
	})

	self.pause.Activated:Connect(function()
		if self.machine then
			self:setPaused(not self.paused)
		end
	end)
	self.step.Activated:Connect(function()
		if self.machine and self.paused then
			self.stepPending = true
			self.message = "Step requested"
			self:refresh()
		end
	end)
	self.action.Activated:Connect(function()
		self:actionPressed()
	end)
	self.extra.Activated:Connect(function()
		self:writeByte()
	end)
	self.navPrev.Activated:Connect(function()
		self.memoryAddress = band((self.memoryAddress or 0) - DUMP_BYTES_PER_ROW * DUMP_ROWS, 0xFFFFFFFF)
		self.message = "Previous page"
		self:refresh()
	end)
	self.navNext.Activated:Connect(function()
		self.memoryAddress = band((self.memoryAddress or 0) + DUMP_BYTES_PER_ROW * DUMP_ROWS, 0xFFFFFFFF)
		self.message = "Next page"
		self:refresh()
	end)
	self.navIP.Activated:Connect(function()
		if self.machine then
			local cpu = self.machine.cpu
			local cs = cpu.s and cpu.s[2]
			local base = segBase(cs)
			if base then
				self.memoryAddress = band(base + cpu.ip, 0xFFFFFFFF)
				self.message = "Jumped to CS:EIP linear address"
				self:refresh()
			end
		end
	end)
	self.navSP.Activated:Connect(function()
		if self.machine then
			local cpu = self.machine.cpu
			local ss = cpu.s and cpu.s[3]
			local base = segBase(ss)
			if base then
				self.memoryAddress = band(base + cpu.r[5], 0xFFFFFFFF)
				self.message = "Jumped to SS:ESP linear address"
				self:refresh()
			end
		end
	end)
	return self
end

function Debugger:reflow()
	local y = 0
	for _, section in self.visibleSections do
		local height = HEADER_HEIGHT
		section.container.Position = UDim2.fromOffset(0, y)
		section.header.Text = (if section.expanded then "  −  " else "  +  ") .. section.name
		for i, row in section.rows do
			row.frame.Visible = section.expanded and i <= section.count
			if row.frame.Visible then
				row.frame.Position = UDim2.fromOffset(0, height)
				height += row.frame.Size.Y.Offset
			end
		end
		section.container.Size = UDim2.new(1, 0, 0, height)
		y += height + SECTION_GAP
	end
	local height = math.max(0, y - SECTION_GAP)
	self.scroll.CanvasSize = UDim2.fromOffset(0, height)
	self.scroll.CanvasPosition = Vector2.new(0, math.min(self.scroll.CanvasPosition.Y, math.max(0, height - self.scroll.AbsoluteWindowSize.Y)))
end

function Debugger:showSections(definitions)
	for _, section in self.sections do
		section.container.Visible = false
	end
	table.clear(self.visibleSections)
	for _, definition in definitions do
		local name, entries, defaultOpen = definition[1], definition[2], definition[3]
		local key = self.tab .. ":" .. name
		local section = self.sections[key]
		if not section then
			local container = make(self.scroll, "Frame", {Name = name, BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 2})
			local header = make(container, "TextButton", {
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				BackgroundColor3 = self.headerColor,
				BorderSizePixel = 0,
				TextColor3 = self.fg,
				FontFace = MEDIUM,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 3,
			})
			section = {name = name, container = container, header = header, rows = {}, count = 0, expanded = defaultOpen == true}
			self.sections[key] = section
			header.Activated:Connect(function()
				section.expanded = not section.expanded
				self:reflow()
			end)
		end
		section.count = #entries
		section.container.Visible = true
		self.visibleSections[#self.visibleSections + 1] = section
		for i, entry in entries do
			local row = section.rows[i]
			if not row then
				local frame = make(section.container, "Frame", {BackgroundTransparency = 1, ZIndex = 2})
				local caption = make(frame, "TextLabel", {
					Position = UDim2.fromOffset(8, 0),
					Size = UDim2.new(0.38, -10, 1, 0),
					BackgroundTransparency = 1,
					TextColor3 = self.muted,
					FontFace = FONT,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 3,
				})
				local value = make(frame, "TextLabel", {
					BackgroundTransparency = 1,
					TextColor3 = self.fg,
					FontFace = MONO,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextWrapped = true,
					ZIndex = 3,
				})
				row = {frame = frame, caption = caption, value = value}
				section.rows[i] = row
			end
			local full = entry[1] == ""
			row.caption.Visible = not full
			row.caption.Text = entry[1]
			row.value.Position = if full then UDim2.fromOffset(8, 0) else UDim2.new(0.38, 2, 0, 0)
			row.value.Size = if full then UDim2.new(1, -16, 1, 0) else UDim2.new(0.62, -10, 1, 0)
			row.value.TextXAlignment = if full then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
			row.value.FontFace = if entry[4] then FONT else MONO
			row.value.Text = entry[2]
			row.frame.Size = UDim2.new(1, 0, 0, entry[3] or ROW_HEIGHT)
		end
		for i = #entries + 1, #section.rows do
			section.rows[i].frame.Visible = false
		end
	end
	self:reflow()
end

function Debugger:detach()
	self.beforeInstruction = nil
end

function Debugger:setMachine(machine)
	self:detach()
	self.machine = machine
	self.paused = self.group.Visible and machine ~= nil
	self.stepPending = false
	self.breakHit = nil
	self.skipOnce = nil
	self.message = if machine then (if self.paused then "Paused" else "Ready") else "Open a machine first"
	if machine and self.group.Visible then
		self.beforeInstruction = function(cpu)
			local key = address(cpu)
			local skip = self.skipOnce
			self.skipOnce = nil
			if self.breakpoints[key] and skip ~= key then
				self.breakHit = key
				return true
			end
			return false
		end
	end
	self:refresh()
end

function Debugger:setVisible(visible, machine)
	self.group.Visible = visible
	self:setMachine(machine)
end

function Debugger:setPaused(paused)
	self.paused = paused
	self.stepPending = false
	if not paused and self.breakHit and self.machine then
		self.skipOnce = address(self.machine.cpu)
	end
	self.breakHit = nil
	self.message = if paused then "Paused" else "Running"
	self:refresh()
end

function Debugger:breakpointHook()
	return if self.group.Visible and next(self.breakpoints) then self.beforeInstruction else nil
end

function Debugger:singleStep()
	self.stepPending = false
	self.breakHit = nil
	self.skipOnce = nil
	local ok, reset, reason = pcall(self.machine.debugStep, self.machine)
	if ok then
		self.message = if reset then "Guest reset" elseif reason == "idle" then "HLT: advanced idle clocks" else "Stepped one dispatch"
	else
		self.message = "Step error: " .. tostring(reset)
	end
	self:refresh()
	return ok, reset
end

function Debugger:breakpointStopped()
	self.paused = true
	self.message = "Breakpoint " .. (self.breakHit or "")
	self:refresh()
end

function Debugger:contains(p)
	local g = self.group
	local a, s = g.AbsolutePosition, g.AbsoluteSize
	return g.Visible and p.X >= a.X and p.Y >= a.Y and p.X < a.X + s.X and p.Y < a.Y + s.Y
end

function Debugger:actionPressed()
	if not self.machine then
		return
	end
	if self.tab == "CPU" then
		local raw = self.input.Text
		local a, b = raw:match("^%s*(%x+):(%x+)%s*$")
		local cs = if a then parseHex(a) else nil
		local ip = if b then parseHex(b) else nil
		local key
		if raw:match("^%s*$") then
			key = address(self.machine.cpu)
		elseif cs and ip and cs <= 0xFFFF then
			key = fmt("%04X:%08X", cs, ip)
		end
		if not key then
			self.message = "Use hexadecimal CS:EIP"
			self:refresh()
			return
		end
		self.breakpoints[key] = if self.breakpoints[key] then nil else true
		self.message = "Breakpoint " .. (if self.breakpoints[key] then "added" else "removed")
	elseif self.tab == "Memory" then
		local a = parseHex(self.input.Text)
		if not a then
			self.message = "Invalid hexadecimal address"
		else
			self.memoryAddress = a
			self.message = "Memory refreshed"
		end
	end
	self:refresh()
end

function Debugger:writeByte()
	if self.tab ~= "Memory" or not self.machine or not self.paused or self.stepPending then
		return
	end
	local a, b = parseHex(self.input.Text), parseHex(self.value.Text)
	local bus = self.machine.bus
	if not a or not b or b > 255 then
		self.message = "Use address and byte in hex"
	elseif not bus:ramSpan(a, 1) then
		self.message = "Write restricted to mapped guest RAM"
	else
		bus:write8(a, b)
		self.memoryAddress = a
		self.message = "Guest byte written"
	end
	self:refresh()
end

function Debugger:refresh()
	if not self.group.Visible then
		return
	end
	self.pause.Text = if self.paused then "Resume" else "Pause"
	self.step.Text = if self.stepPending then "Stepping…" else "Step"
	self.step.TextColor3 = if self.paused and self.machine then self.fg else self.muted
	self.status.Text = self.message
	for name, button in self.tabs do
		button.BackgroundColor3 = self.bg:Lerp(self.fg, if name == self.tab then 0.17 else 0.08)
	end
	local mem = self.tab == "Memory"
	local cpuTab = self.tab == "CPU"
	if self.previousTab ~= self.tab then
		self.input.Text = if mem then hex(self.memoryAddress or 0) else ""
		self.scroll.CanvasPosition = Vector2.zero
		self.previousTab = self.tab
	end
	self.input.Visible = mem or cpuTab
	self.action.Visible = mem or cpuTab
	self.input.PlaceholderText = if mem then "Linear or physical hex address" else "CS:EIP or current"
	self.action.Text = if mem then "Inspect" else "Toggle BP"
	self.value.Visible = mem
	self.extra.Visible = mem
	self.navPrev.Visible = mem
	self.navNext.Visible = mem
	self.navIP.Visible = mem
	self.navSP.Visible = mem
	self.extra.TextColor3 = if self.paused and self.machine then self.fg else self.muted
	local top = if mem then 198 elseif cpuTab then 140 else 112
	self.scroll.Position = UDim2.fromOffset(0, top)
	self.scroll.Size = UDim2.new(1, 0, 1, -top)
	if not self.machine then
		self:showSections({{"Machine", {{"Status", "No machine", nil, true}}, true}})
		return
	end
	local cpu, bus, board = self.machine.cpu, self.machine.bus, self.machine.board
	local sections = {}
	local function add(name, rows, expanded)
		sections[#sections + 1] = {name, rows, expanded}
	end
	if cpuTab then
		local raw, mnemonic = decode(cpu, bus)
		local width = if cpu.codeMask == 0xFFFF then 16 else 32
		add("Summary", {
			{"Mode", cpuMode(cpu) .. " / " .. tostring(width) .. "-bit"},
			{"CPL", privilege(cpu)},
			{"CS:EIP", address(cpu)},
			{"State", if cpu.halted then "HLT" else "Ready"},
			{"Current bytes", raw, 40},
			{"Decoded", mnemonic, 40, true},
		}, true)
		local r = cpu.r
		add("General registers", {
			{"EAX / EBX", hex(r[1]) .. " / " .. hex(r[4])},
			{"ECX / EDX", hex(r[2]) .. " / " .. hex(r[3])},
			{"ESI / EDI", hex(r[7]) .. " / " .. hex(r[8])},
			{"ESP / EBP", hex(r[5]) .. " / " .. hex(r[6])},
		}, true)
		add("Flags and control", {
			{"EFLAGS", hex(cpu.flags)},
			{"Flags", flagString(cpu.flags), 40, true},
			{"CR0 / CR2", if cpu.control then hex(cpu.control[0]) .. " / " .. hex(cpu.control[2]) else "—"},
			{"CR3 / CR4", if cpu.control then hex(cpu.control[3]) .. " / " .. hex(cpu.control[4]) else "—"},
		}, false)
		local segRows = {}
		for i, name in {"ES", "CS", "SS", "DS", "FS", "GS"} do
			local seg = cpu.s[i]
			if type(seg) == "table" then
				segRows[#segRows + 1] = {name, hex(seg.selector, 4) .. " / " .. hex(seg.base)}
				segRows[#segRows + 1] = {"Limit / AR", hex(seg.limit) .. " / " .. hex(seg.accessRights)}
			elseif seg ~= nil then
				segRows[#segRows + 1] = {name, hex(seg, 4) .. " / " .. hex(seg * 16)}
			end
		end
		add("Segment caches (sel / base)", segRows, false)
		local descriptors = {}
		for _, pair in {{"GDTR", cpu.gdt}, {"IDTR", cpu.idt}, {"LDTR", cpu.ldt}, {"TR", cpu.tr}} do
			local d = pair[2]
			if type(d) == "table" then
				descriptors[#descriptors + 1] = {pair[1], hex(d.base) .. " / " .. hex(d.limit)}
			end
		end
		if #descriptors == 0 then
			descriptors[1] = {"Status", "Unavailable", nil, true}
		end
		add("Descriptor tables (base / limit)", descriptors, false)
		add("Stack preview", stackRows(cpu, bus), false)
		local bps = {}
		for key in self.breakpoints do
			bps[#bps + 1] = key
		end
		table.sort(bps)
		local bpRows = {{"Count", tostring(#bps)}}
		if #bps == 0 then
			bpRows[#bpRows + 1] = {"Active", "None", nil, true}
		else
			for i, key in bps do
				bpRows[#bpRows + 1] = {tostring(i), key}
			end
		end
		add("Breakpoints", bpRows, false)
		local debugRows = {}
		if cpu.debugRegisters then
			for _, i in {0, 1, 2, 3, 6, 7} do
				debugRows[#debugRows + 1] = {"DR" .. i, hex(cpu.debugRegisters[i])}
			end
		else
			debugRows[1] = {"Status", "Unavailable", nil, true}
		end
		add("Debug registers", debugRows, false)
	elseif mem then
		local a = self.memoryAddress or 0
		local rows = {}
		for offset = 0, DUMP_BYTES_PER_ROW * DUMP_ROWS - DUMP_BYTES_PER_ROW, DUMP_BYTES_PER_ROW do
			local bytes, ascii = {}, {}
			for i = 0, DUMP_BYTES_PER_ROW - 1 do
				local v = peek(bus, a + offset + i)
				bytes[#bytes + 1] = hex(v, 2)
				ascii[#ascii + 1] = if v and v >= 32 and v <= 126 then string.char(v) else "."
			end
			rows[#rows + 1] = {"", hex(band(a + offset, 0xFFFFFFFF)) .. "  " .. table.concat(bytes, " ") .. "  |" .. table.concat(ascii) .. "|", 22}
		end
		add("Memory summary", {
			{"Address", hex(a)},
			{"Region", regionName(bus, a), nil, true},
			{"A20", if bus.a20 then "Enabled" else "Disabled", nil, true},
			{"Writes", if self.paused then "Allowed to guest RAM" else "Pause to edit", nil, true},
		}, true)
		add("Hex dump (bus view)", rows, true)
		local phys, pde, pte, info = walk(cpu, bus, a)
		add("Page walk (linear address)", {
			{"Linear", hex(a)},
			{"PDE", hex(pde)},
			{"PTE", hex(pte)},
			{"Physical", hex(phys)},
			{"Permissions", info, 36, true},
		}, false)
	else
		local dma, pit, vga, pic, slave = board.dma, board.pit, bus.vga, board.pic, board.slavePic
		local conventional, extended = bus:ramKiB()
		add("Machine", {
			{"RAM", tostring(conventional) .. " KiB / " .. tostring(extended) .. " KiB ext", nil, true},
			{"A20", if bus.a20 then "Enabled" else "Disabled", nil, true},
			{"Clock", tostring(board.clockRate) .. " Hz", nil, true},
			{"PIC pending", hex(pic.pending, 2) .. (if slave then " / " .. hex(slave.pending, 2) else "")},
			{"Keyboard queue", tostring(#board.keyboard), nil, true},
		}, true)
		local dmaRows = {}
		if dma then
			dmaRows = {{"Mask / stat / cmd", hex(dma.mask, 2) .. " / " .. hex(dma.status, 2) .. " / " .. hex(dma.command, 2)}}
			for i = 0, 3 do
				local c = dma.channels[i]
				if c then
					dmaRows[#dmaRows + 1] = {"CH" .. i .. " addr / count", hex(c.page, 2) .. ":" .. hex(c.address, 4) .. " / " .. hex(c.count, 4)}
					dmaRows[#dmaRows + 1] = {"Base / mode", hex(c.baseAddress, 4) .. " / " .. hex(c.baseCount, 4) .. " / " .. hex(c.mode, 2)}
				end
			end
		else
			dmaRows[1] = {"Status", "Unavailable", nil, true}
		end
		add("DMA 8237", dmaRows, false)
		local pitRows = {}
		if pit then
			for i = 0, 2 do
				local c = pit.channels[i]
				if c then
					pitRows[#pitRows + 1] = {"CH" .. i .. " mode / gate", tostring(c.mode) .. " / " .. tostring(c.gate)}
					pitRows[#pitRows + 1] = {"Reload / count", fmt("%d / %d", c.reload, pit:counter(c))}
				end
			end
		else
			pitRows[1] = {"Status", "Unavailable", nil, true}
		end
		add("PIT 8253", pitRows, false)
		if vga then
			add("VGA state", {
				{"Misc / pixel mask", hex(vga.miscellaneous, 2) .. " / " .. hex(vga.pixelMask, 2)},
				{"Latches", hex(vga.latches)},
			}, false)
			add("VGA sequencer", registerRows(vga.sequencer), false)
			add("VGA graphics controller", registerRows(vga.graphics), false)
			add("VGA attribute controller", registerRows(vga.attribute), false)
			add("VGA CRTC", registerRows(vga.crtc), false)
		else
			add("VGA", {{"Status", "Not installed", nil, true}}, false)
		end
	end
	self:showSections(sections)
end

return Debugger
