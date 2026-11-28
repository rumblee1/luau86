--!optimize 2

local Bus = if script then require(script.Parent.Bus) else require("./Bus")
local Cpu8088 = if script then require(script.Parent.Cpu8088) else require("./Cpu8088")

local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot
local shiftRight, extract = bit32.rshift, bit32.extract
local ES, CS, SS, DS, FS, GS = 1, 2, 3, 4, 5, 6
local CF, ZF, IF, DF, OF = 0x1, 0x40, 0x200, 0x400, 0x800
local UINT16, UINT32 = 0xFFFF, 0xFFFFFFFF
local PE, VM, PG = 1, 0x20000, 0x80000000

local Cpu = setmetatable({}, { __index = Cpu8088 })
Cpu.__index = Cpu

local function signed(value, sign)
	return value < sign and value or value - 2 * sign
end

local function widthBytes(width)
	return width == 32 and 4 or (width and 2 or 1)
end

local function widthMask(width)
	return width == 32 and UINT32 or (width and UINT16 or 0xFF)
end

local function realSegment(selector, base)
	return { selector = selector, base = base or selector * 16, limit = UINT16, readLimit = UINT16, writeLimit = UINT16 }
end

local function fault(vector, code)
	error({ vector = vector, code = code }, 0)
end

function Cpu.new(bus)
	local self = Cpu8088.new(bus)
	self.is386 = true
	self.flags = 2
	self.s = {
		realSegment(0),
		realSegment(0xF000, 0xFFFF0000),
		realSegment(0),
		realSegment(0),
		realSegment(0),
		realSegment(0),
	}
	self.ip = 0xFFF0
	self.control = { [0] = 0x10, [2] = 0, [3] = 0 }
	self.debugRegisters = { [0] = 0, 0, 0, 0, [6] = 0xFFFF0FF0, [7] = 0x400 }
	self.gdt = { base = 0, limit = UINT16 }
	self.idt = { base = 0, limit = 0x3FF }
	self.cpl = 0
	return setmetatable(self, Cpu)
end

function Cpu:protected()
	return band(self.control[0], PE) ~= 0
end

function Cpu:virtual8086()
	return self:protected() and band(self.flags, VM) ~= 0
end

function Cpu:translate(linear, write, supervisor)
	linear = band(linear, UINT32)
	if band(self.control[0], PG) == 0 then
		return linear
	end
	local bus = self.bus
	local directory = band(self.control[3], 0xFFFFF000) + extract(linear, 22, 10) * 4
	local pde = bus:readPhysical32(directory)
	local present = band(pde, 1) ~= 0
	local entry = band(pde, 0xFFFFF000) + extract(linear, 12, 10) * 4
	local pte = present and bus:readPhysical32(entry) or 0
	present = present and band(pte, 1) ~= 0
	local user = not supervisor and self.cpl == 3
	local permission = band(pde, pte)
	if not present or (user and (band(permission, 4) == 0 or (write and band(permission, 2) == 0))) then
		self.control[2] = linear
		fault(14, (present and 1 or 0) + (write and 2 or 0) + (user and 4 or 0))
	end

	if band(pde, 0x20) == 0 then
		bus:writePhysical32(directory, bor(pde, 0x20))
	end
	local flags = write and 0x60 or 0x20
	if band(pte, flags) ~= flags then
		bus:writePhysical32(entry, bor(pte, flags))
	end
	return band(pte, 0xFFFFF000) + band(linear, 0xFFF)
end

function Cpu:readLinear(linear, size, supervisor)
	local paging = band(self.control[0], PG) ~= 0
	local bus = self.bus
	local memory = bus.memory
	if
		not paging
		and linear >= 0
		and (
			linear + size <= Bus.CONVENTIONAL_BYTES
			or (bus.a20 and linear >= 0x100000 and linear + size <= buffer.len(memory))
		)
	then
		if size == 1 then
			return buffer.readu8(memory, linear)
		elseif size == 2 then
			return buffer.readu16(memory, linear)
		elseif size == 4 then
			return buffer.readu32(memory, linear)
		end
	end
	local first = if paging then self:translate(linear, false, supervisor) else band(linear, UINT32)
	if size == 1 then
		return self.bus:read8(first)
	elseif size == 4 and band(linear, 3) == 0 then
		return self.bus:readPhysical32(first)
	end
	if band(linear, 0xFFF) + size <= 0x1000 then
		local value = 0
		for index = 0, size - 1 do
			value += self.bus:read8(first + index) * 256 ^ index
		end
		return value
	end
	local value = 0
	for index = 0, size - 1 do
		value += self.bus:read8(self:translate(linear + index, false, supervisor)) * 256 ^ index
	end
	return value
end

function Cpu:writeLinear(linear, size, value, supervisor)
	local paging = band(self.control[0], PG) ~= 0
	local bus = self.bus
	local memory = bus.memory
	if
		not paging
		and linear >= 0
		and (
			linear + size <= Bus.CONVENTIONAL_BYTES
			or (bus.a20 and linear >= 0x100000 and linear + size <= buffer.len(memory))
		)
	then
		if size == 1 then
			buffer.writeu8(memory, linear, value)
			return
		elseif size == 2 then
			buffer.writeu16(memory, linear, value)
			return
		elseif size == 4 then
			buffer.writeu32(memory, linear, value)
			return
		end
	end
	local first = if paging then self:translate(linear, true, supervisor) else band(linear, UINT32)
	if size == 1 then
		self.bus:write8(first, band(value, 0xFF))
		return
	elseif size == 4 and band(linear, 3) == 0 then
		self.bus:writePhysical32(first, value)
		return
	end
	local second
	local split = 0x1000 - band(linear, 0xFFF)
	if size > split then
		second = self:translate(linear + split, true, supervisor)
	end
	for index = 0, size - 1 do
		local address = index < split and first + index or second + index - split
		self.bus:write8(address, extract(value, index * 8, 8))
	end
end

function Cpu:segmentAddress(segment, offset, size, write, stack)
	local endOffset = offset + size - 1
	local inRange = endOffset <= segment.limit
	if segment.expandDown then
		inRange = offset > segment.limit and endOffset <= (segment.big and UINT32 or UINT16)
	end
	if
		segment.unusable
		or not inRange
		or (write and segment.writable == false)
		or (not write and segment.readable == false)
	then
		fault(stack and 12 or 13, 0)
	end
	return band(segment.base + offset, UINT32)
end

function Cpu:read(segment, offset, width)
	local size = widthBytes(width)
	local linear = segment.base + offset
	local bus = self.bus
	local memory = bus.memory
	if
		segment.readLimit
		and offset + size - 1 <= segment.readLimit
		and band(self.control[0], PG) == 0
		and (
			(linear >= 0 and linear + size <= Bus.CONVENTIONAL_BYTES)
			or (bus.a20 and linear >= 0x100000 and linear + size <= buffer.len(memory))
		)
	then
		if size == 1 then
			return buffer.readu8(memory, linear)
		elseif size == 2 then
			return buffer.readu16(memory, linear)
		end
		return buffer.readu32(memory, linear)
	end
	return self:readLinear(self:segmentAddress(segment, offset, size, false, segment == self.s[SS]), size)
end

function Cpu:write(segment, offset, width, value)
	local size = widthBytes(width)
	local linear = segment.base + offset
	local bus = self.bus
	local memory = bus.memory
	if
		segment.writeLimit
		and offset + size - 1 <= segment.writeLimit
		and band(self.control[0], PG) == 0
		and (
			(linear >= 0 and linear + size <= Bus.CONVENTIONAL_BYTES)
			or (bus.a20 and linear >= 0x100000 and linear + size <= buffer.len(memory))
		)
	then
		if size == 1 then
			buffer.writeu8(memory, linear, value)
		elseif size == 2 then
			buffer.writeu16(memory, linear, value)
		else
			buffer.writeu32(memory, linear, value)
		end
		return
	end
	self:writeLinear(self:segmentAddress(segment, offset, size, true, segment == self.s[SS]), size, value)
end

local function repeatAddress(cpu, segment, offset, length)
	if segment.unusable or segment.expandDown or offset + length - 1 > math.min(segment.limit, cpu.addressMask) then
		return nil
	end
	return segment.base + offset
end

local function repeatCodeIsSafe(cpu, startIp, target, length)
	local bus = cpu.bus
	local code = cpu.s[CS].base + startIp
	local size = cpu.ip - startIp
	local first = bus:physical(code)
	return size > 0
		and bus:physical(code + size - 1) == first + size - 1
		and (target >= first + size or first >= target + length)
end

local function repeatIterations(cpu, count, limit, checkDevices)
	local iterations = math.min(count, limit)
	if iterations > 1 and (checkDevices or band(cpu.flags, IF) ~= 0) then
		local board = cpu.bus.io
		return if board then math.min(iterations, board:clocksUntilIrq()) else 1
	end
	return iterations
end

function Cpu:repeatMemory(opcode, segment, startIp, width, addressSize, count, iterations)
	local bus = self.bus
	local size = widthBytes(width)
	local length = iterations * size
	local es = self.s[ES]
	local di = self:getRegister(7, addressSize)
	local targetAddress = es.writable ~= false and repeatAddress(self, es, di, length)
	if not targetAddress then
		return false
	end
	local moving = opcode == 0xA4 or opcode == 0xA5
	local target = bus:ramSpan(targetAddress, length)
	if not target and not moving then
		return false
	end

	local mappedTarget = target or bus:physical(targetAddress)
	if not repeatCodeIsSafe(self, startIp, mappedTarget, length) then
		return false
	end

	local memory = bus.memory
	if moving then
		local si = self:getRegister(6, addressSize)
		local sourceAddress = segment.readable ~= false and repeatAddress(self, segment, si, length)
		local source = sourceAddress and bus:ramSpan(sourceAddress, length)
		if not source then
			return false
		end
		if target then
			-- Forward REP can observe its own writes when the spans overlap.
			if source < target and target < source + length then
				return false
			end
			buffer.copy(memory, target, memory, source, length)
		elseif not bus:copyRamToVga(targetAddress, mappedTarget, source, length) then
			return false
		end
		self:setRegister(6, addressSize, si + length)
	else
		local value = self:getRegister(0, width)
		local byte = band(value, 255)
		if size == 1 or value == byte * (size == 2 and 0x0101 or 0x01010101) then
			buffer.fill(memory, target, byte, length)
		elseif size == 2 then
			for offset = target, target + length - 1, 2 do
				buffer.writeu16(memory, offset, value)
			end
		else
			for offset = target, target + length - 1, 4 do
				buffer.writeu32(memory, offset, value)
			end
		end
	end
	self:setRegister(7, addressSize, di + length)
	self:setRegister(1, addressSize, count - iterations)
	if count > iterations then
		self.ip = startIp
	end
	return true
end

function Cpu:repeatVgaBytes(segment, startIp, addressSize, count, iterations, backwards)
	local bus, es = self.bus, self.s[ES]
	local si, di = self:getRegister(6, addressSize), self:getRegister(7, addressSize)
	local back = if backwards then iterations - 1 else 0
	if si < back or di < back then
		return false
	end
	local source = segment.readable ~= false and repeatAddress(self, segment, si - back, iterations)
	local target = es.writable ~= false and repeatAddress(self, es, di - back, iterations)
	if
		not source
		or not target
		or not repeatCodeIsSafe(self, startIp, bus:physical(target), iterations)
		or not bus:copyPlanarVga(target, source, iterations, backwards)
	then
		return false
	end
	local delta = if backwards then -iterations else iterations
	self:setRegister(6, addressSize, si + delta)
	self:setRegister(7, addressSize, di + delta)
	self:setRegister(1, addressSize, count - iterations)
	if count > iterations then
		self.ip = startIp
	end
	return true
end

function Cpu:stringInstruction(opcode, segment, repeatPrefix, startIp, repeatLimit, wide)
	local limit = repeatLimit or 1
	local interrupts = band(self.flags, IF) ~= 0
	local backwards = band(self.flags, DF) ~= 0
	if
		limit > 1
		and repeatPrefix
		and (opcode == 0xA4 or opcode == 0xA5 or opcode == 0xAA or opcode == 0xAB)
		and (not backwards or opcode == 0xA4)
		and band(self.control[0], PG) == 0
	then
		local addressSize = self.addressMask == UINT32 and 32 or true
		local count = self:getRegister(1, addressSize)
		local iterations = repeatIterations(self, count, limit)
		if iterations > 1 then
			if not backwards and self:repeatMemory(opcode, segment, startIp, wide, addressSize, count, iterations) then
				return iterations
			end
			if opcode == 0xA4 then
				local vgaIterations = if interrupts then iterations else repeatIterations(self, count, limit, true)
				if
					vgaIterations > 1
					and self:repeatVgaBytes(segment, startIp, addressSize, count, vgaIterations, backwards)
				then
					return vgaIterations
				end
			end
		end
	end
	return Cpu8088.stringInstruction(
		self,
		opcode,
		segment,
		repeatPrefix,
		startIp,
		if interrupts then 1 else limit,
		wide
	)
end

function Cpu:fetch8()
	local segment = self.s[CS]
	if self.ip > segment.limit then
		fault(13, 0)
	end
	local linear = segment.base + self.ip
	local bus = self.bus
	local value
	if band(self.control[0], PG) ~= 0 then
		value = bus:read8(self:translate(linear, false))
	elseif
		(linear >= 0 and linear < Bus.CONVENTIONAL_BYTES)
		or (bus.a20 and linear >= 0x100000 and linear < buffer.len(bus.memory))
	then
		value = buffer.readu8(bus.memory, linear)
	else
		value = bus:read8(linear)
	end
	self.ip = band(self.ip + 1, self.codeMask)
	return value
end

function Cpu:fetch(wide)
	if not wide then
		return self:fetch8()
	end
	local size = widthBytes(wide)
	local segment = self.s[CS]
	local offset = self.ip
	local linear = segment.base + offset
	local last = offset + size - 1
	local bus = self.bus
	local memory = bus.memory
	if
		last <= segment.limit
		and last <= self.codeMask
		and (linear + size <= Bus.CONVENTIONAL_BYTES or (bus.a20 and linear >= 0x100000 and linear + size <= buffer.len(
			memory
		)))
		and band(self.control[0], PG) == 0
	then
		self.ip = band(offset + size, self.codeMask)
		return if size == 2 then buffer.readu16(memory, linear) else buffer.readu32(memory, linear)
	end
	return Cpu8088.fetch(self, wide)
end

function Cpu:descriptor(selector, probe)
	local code = band(selector, 0xFFFC)
	local offset = band(selector, 0xFFF8)
	local table = if band(selector, 4) == 0 then self.gdt else self.ldt
	if table == nil or offset + 7 > table.limit then
		if probe then
			return nil
		end
		fault(13, code)
	end
	local address = table.base + offset
	local low, high = self:readLinear(address, 4, true), self:readLinear(address + 4, 4, true)
	local access = extract(high, 8, 8)
	local limit = band(low, UINT16) + band(high, 0x000F0000)
	if band(high, 0x00800000) ~= 0 then
		limit = limit * 4096 + 4095
	end
	local system = band(access, 0x10) == 0
	local executable = not system and band(access, 8) ~= 0
	local base = shiftRight(low, 16) + band(high, 0xFF) * 0x10000 + band(high, 0xFF000000)
	local readable = not executable or band(access, 2) ~= 0
	local writable = not executable and band(access, 2) ~= 0
	local expandDown = not system and not executable and band(access, 4) ~= 0
	-- Ordinary readable and writable segments can use the RAM path.
	-- Expand-down segments require the general bounds check.
	return {
		selector = selector,
		address = address,
		accessRights = band(high, 0x00F0FF00),
		base = base,
		limit = limit,
		big = band(high, 0x00400000) ~= 0,
		present = band(access, 0x80) ~= 0,
		dpl = extract(access, 5, 2),
		kind = band(access, 15),
		system = system,
		executable = executable,
		conforming = executable and band(access, 4) ~= 0,
		readable = readable,
		writable = writable,
		expandDown = expandDown,
		readLimit = if readable and not expandDown then limit else nil,
		writeLimit = if writable and not expandDown then limit else nil,
	}
end

function Cpu:selector(index)
	return self.s[index].selector
end

function Cpu:loadSegment(index, value)
	local selector = band(value, UINT16)
	local segment
	if not self:protected() or self:virtual8086() then
		segment = realSegment(selector)
		if index ~= CS and not self:virtual8086() then
			-- A real-mode load changes the base but retains the cached limit.
			segment.limit = self.s[index].limit
			segment.readLimit, segment.writeLimit = segment.limit, segment.limit
		end
	elseif band(selector, 0xFFFC) == 0 and index ~= CS and index ~= SS then
		segment = { selector = selector, unusable = true, base = 0, limit = 0 }
	else
		local code, rpl = band(selector, 0xFFFC), band(selector, 3)
		if code == 0 then
			fault(13, 0)
		end
		segment = self:descriptor(selector)
		local valid = not segment.system
		if index == CS then
			valid = valid
				and segment.executable
				and (
					segment.conforming and segment.dpl <= self.cpl
					or not segment.conforming and segment.dpl == self.cpl and rpl <= self.cpl
				)
			segment.selector = code + self.cpl
		elseif index == SS then
			valid = valid and segment.writable and segment.dpl == self.cpl and rpl == self.cpl
		else
			valid = valid and segment.readable and (segment.conforming or math.max(self.cpl, rpl) <= segment.dpl)
		end
		if not valid then
			fault(13, code)
		end
		if not segment.present then
			fault(index == SS and 12 or 11, code)
		end
	end
	self.s[index] = segment
	if index == CS then
		self.codeMask = segment.big and UINT32 or UINT16
	end
end

function Cpu:getRegister(index, width)
	if width == 32 then
		return self.r[index + 1]
	elseif width then
		return band(self.r[index + 1], UINT16)
	end
	return Cpu8088.getRegister(self, index, false)
end

function Cpu:setRegister(index, width, value)
	local registers = self.r
	if width == 32 then
		registers[index + 1] = band(value, UINT32)
	elseif width then
		local slot = index + 1
		registers[slot] = bor(band(registers[slot], 0xFFFF0000), band(value, UINT16))
	else
		local slot = band(index, 3) + 1
		registers[slot] = bit32.replace(registers[slot], value, index < 4 and 0 or 8, 8)
	end
end

local function setStackPointer(registers, pointer, mask)
	registers[5] = bor(band(registers[5], bnot(mask)), pointer)
end

function Cpu:adjustStack(delta)
	local mask = if self.s[SS].big then UINT32 else UINT16
	local offset = band(self.r[5] + delta, mask)
	setStackPointer(self.r, offset, mask)
	return offset
end

function Cpu:push(value, width)
	width = width or true
	local stack, registers = self.s[SS], self.r
	local mask = if stack.big then UINT32 else UINT16
	local offset = band(registers[5] - widthBytes(width), mask)
	self:write(stack, offset, width, value)
	setStackPointer(registers, offset, mask)
end

function Cpu:pop(width)
	width = width or true
	local stack, registers = self.s[SS], self.r
	local mask = if stack.big then UINT32 else UINT16
	local offset = band(registers[5], mask)
	local value = self:read(stack, offset, width)
	setStackPointer(registers, band(offset + widthBytes(width), mask), mask)
	return value
end

local LEGACY_ADDRESS = {
	{ 4, 7 }, -- BX + SI
	{ 4, 8 }, -- BX + DI
	{ 6, 7 }, -- BP + SI
	{ 6, 8 }, -- BP + DI
	{ 7 },
	{ 8 },
	{ 6 },
	{ 4 },
}

function Cpu:decodeOperand(override, espAdjustment)
	local modrm = self:fetch8()
	local mode, register, operand = shiftRight(modrm, 6), extract(modrm, 3, 3), band(modrm, 7)
	if mode == 3 then
		return register, operand, nil
	end
	local base, slot = 0, DS
	local wide = self.addressMask == UINT32 and 32 or true
	if wide == 32 then
		local registers = self.r
		local reg = operand
		if reg == 4 then
			local sib = self:fetch8()
			local index = extract(sib, 3, 3)
			if index ~= 4 then
				base = registers[index + 1] * bit32.lshift(1, shiftRight(sib, 6))
			end
			reg = band(sib, 7)
		end
		if reg == 5 and mode == 0 then
			base += self:fetch(32)
		else
			base += registers[reg + 1]
			if reg == 4 and espAdjustment then
				base += espAdjustment
			end
			slot = (reg == 4 or reg == 5) and SS or DS
		end
	elseif mode == 0 and operand == 6 then
		base = self:fetch(true)
	else
		local pair = LEGACY_ADDRESS[operand + 1]
		local registers = self.r
		-- The final 16-bit mask also removes each register's upper bits.
		base = registers[pair[1]] + (pair[2] and registers[pair[2]] or 0)
		slot = pair[1] == 6 and SS or DS
	end
	if mode == 1 then
		base += signed(self:fetch8(), 0x80)
	elseif mode == 2 then
		base += self:fetch(wide)
	end
	return register, band(base, self.addressMask), self.s[override or slot]
end

function Cpu:restoreFlags(value, width, allowVirtual)
	local mask = width == 32 and 0x00037FD5 or 0x7FD5
	if not allowVirtual then
		mask = band(mask, bnot(VM))
	end
	if self:protected() and self.cpl ~= 0 then
		mask = band(mask, bnot(0x23000))
	end
	if self:protected() and self.cpl > extract(self.flags, 12, 2) then
		mask = band(mask, bnot(IF))
	end
	self.flags = bor(band(self.flags, bnot(mask)), band(value, mask), 2)
end

function Cpu:interrupt(vector, software, errorCode)
	local width = true
	local offset, selector, target
	local virtual8086 = self:virtual8086()
	local savedFlags = self.flags
	if self:protected() then
		local address = vector * 8
		local code = address + 2
		if address + 7 > self.idt.limit then
			fault(13, code)
		end
		address += self.idt.base
		local low = self:readLinear(address, 4, true)
		local high = self:readLinear(address + 4, 4, true)
		local access, kind = extract(high, 8, 8), extract(high, 8, 5)
		if
			(kind ~= 6 and kind ~= 7 and kind ~= 14 and kind ~= 15)
			or (software and self.cpl > extract(access, 5, 2))
		then
			fault(13, code)
		end
		if band(access, 0x80) == 0 then
			fault(11, code)
		end
		width = kind >= 14 and 32 or true
		offset = band(low, UINT16) + (width == 32 and band(high, 0xFFFF0000) or 0)
		selector = shiftRight(low, 16)
		if band(selector, 0xFFFC) == 0 then
			fault(13, 0)
		end
		target = self:descriptor(selector)
		if not target.executable or target.dpl > self.cpl or offset > target.limit then
			fault(13, band(selector, 0xFFFC))
		end
		if not target.present then
			fault(11, band(selector, 0xFFFC))
		end
		if virtual8086 and (target.dpl ~= 0 or target.conforming) then
			fault(13, band(selector, 0xFFFC))
		end
		if target.dpl < self.cpl and not target.conforming then
			local tr = self.tr
			if not tr or (virtual8086 and (width ~= 32 or not tr.big)) then
				fault(10, 0)
			end
			local slot = tr.big and 4 + target.dpl * 8 or 2 + target.dpl * 4
			local size = tr.big and 4 or 2
			if slot + size + 1 > tr.limit then
				fault(10, band(tr.selector, 0xFFFC))
			end
			local stack = self:readLinear(tr.base + slot, size, true)
			local ss = self:readLinear(tr.base + slot + size, 2, true)
			local oldStack, oldSs = self.r[5], self:selector(SS)
			if virtual8086 then
				self.flags = band(self.flags, bnot(VM))
			end
			self.cpl = target.dpl
			self:loadSegment(SS, ss)
			self.r[5] = stack
			if virtual8086 then
				for _, index in { GS, FS, DS, ES } do
					self:push(self:selector(index), 32)
				end
			end
			self:push(oldSs, width)
			self:push(oldStack, width)
		end
		self:push(savedFlags, width)
		if band(kind, 1) == 0 then
			self.flags = band(self.flags, bnot(IF))
		end
	else
		local address = vector * 4
		if address + 3 > self.idt.limit then
			fault(13, 0)
		end
		address += self.idt.base
		offset = self:readLinear(address, 2, true)
		selector = self:readLinear(address + 2, 2, true)
		self:push(self.flags, width)
		self.flags = band(self.flags, bnot(IF))
	end
	self:push(self:selector(CS), width)
	self:push(self.ip, width)
	if self:protected() and errorCode ~= nil then
		self:push(errorCode, width)
	end
	self.flags = band(self.flags, bnot(0x14100 + (virtual8086 and VM or 0)))
	if virtual8086 then
		for _, index in { ES, DS, FS, GS } do
			self:loadSegment(index, 0)
		end
	end
	self:loadSegment(CS, target and band(selector, 0xFFFC) + self.cpl or selector)
	self.ip = offset
	self.halted = false
	self.interruptShadow = false
end

local TASK_SEGMENTS = { ES, CS, SS, DS, FS, GS }

function Cpu:taskSwitch(selector, operation)
	local code = band(selector, 0xFFFC)
	if code == 0 or band(selector, 4) ~= 0 then
		fault(10, code)
	end
	local target = self:descriptor(selector)
	local expected = operation == "return" and 11 or 9
	if not target.system or target.kind ~= expected or target.limit < 103 then
		fault(10, code)
	end
	if not target.present then
		fault(11, code)
	end
	local old = self.tr
	if not old or not old.big then
		fault(10, 0)
	end
	local oldBase, newBase = old.base, target.base

	-- Task data is fetched with the outgoing task's address space.
	local cr3 = self:readLinear(newBase + 28, 4, true)
	local ip = self:readLinear(newBase + 32, 4, true)
	local flags = self:readLinear(newBase + 36, 4, true)
	local registers, segments = {}, {}
	for index = 1, 8 do
		registers[index] = self:readLinear(newBase + 36 + index * 4, 4, true)
	end
	for _, index in TASK_SEGMENTS do
		segments[index] = self:readLinear(newBase + 68 + index * 4, 2, true)
	end
	local ldt = self:readLinear(newBase + 96, 2, true)

	self:writeLinear(oldBase + 28, 4, self.control[3], true)
	self:writeLinear(oldBase + 32, 4, self.ip, true)
	self:writeLinear(oldBase + 36, 4, operation == "return" and band(self.flags, bnot(0x4000)) or self.flags, true)
	for index = 1, 8 do
		self:writeLinear(oldBase + 36 + index * 4, 4, self.r[index], true)
	end
	for _, index in TASK_SEGMENTS do
		self:writeLinear(oldBase + 68 + index * 4, 2, self:selector(index), true)
	end
	self:writeLinear(oldBase + 96, 2, self.ldt and self.ldt.selector or 0, true)
	if operation ~= "call" then
		local access = old.address + 5
		self:writeLinear(access, 1, band(self:readLinear(access, 1, true), 0xFD), true)
	end
	if operation ~= "return" then
		local access = target.address + 5
		self:writeLinear(access, 1, bor(self:readLinear(access, 1, true), 2), true)
	end
	if operation == "call" then
		self:writeLinear(newBase, 2, old.selector, true)
		flags = bor(flags, 0x4000)
	end

	self.r, self.ip, self.flags = registers, ip, bor(flags, 2)
	self.control[3] = cr3
	self.control[0] = bor(self.control[0], 8)
	target.big = true
	self.tr = target
	self.ldt = nil
	if band(ldt, 0xFFFC) ~= 0 then
		if band(ldt, 4) ~= 0 then
			fault(10, band(ldt, 0xFFFC))
		end
		local table = self:descriptor(ldt)
		if not table.system or table.kind ~= 2 or not table.present then
			fault(10, band(ldt, 0xFFFC))
		end
		self.ldt = table
	end
	self.cpl = band(segments[CS], 3)
	if self:virtual8086() then
		self.cpl = 3
	end
	for _, index in TASK_SEGMENTS do
		self:loadSegment(index, segments[index])
	end
	if ip > self.s[CS].limit then
		fault(13, 0)
	end
end

local function stackOffset(segment, offset)
	return band(offset, if segment.big then UINT32 else UINT16)
end

function Cpu:clearOuterSegments(level)
	for _, index in { ES, DS, FS, GS } do
		local segment = self.s[index]
		if segment.dpl ~= nil and not segment.conforming and segment.dpl < level then
			self:loadSegment(index, 0)
		end
	end
end

function Cpu:enterCodeSegment(target, ip)
	target.selector = band(target.selector, 0xFFFC) + self.cpl
	self.s[CS] = target
	self.codeMask = if target.big then UINT32 else UINT16
	self.ip = ip
end

function Cpu:transferThroughCallGate(gate, call)
	local gateCode = band(gate.selector, 0xFFFC)
	if math.max(self.cpl, band(gate.selector, 3)) > gate.dpl then
		fault(13, gateCode)
	end
	if not gate.present then
		fault(11, gateCode)
	end

	local low = self:readLinear(gate.address, 4, true)
	local high = self:readLinear(gate.address + 4, 4, true)
	local selector = shiftRight(low, 16)
	local targetCode = band(selector, 0xFFFC)
	if targetCode == 0 then
		fault(13, 0)
	end
	local target = self:descriptor(selector)
	if
		not target.executable
		or target.dpl > self.cpl
		or (not call and not target.conforming and target.dpl ~= self.cpl)
	then
		fault(13, targetCode)
	end
	if not target.present then
		fault(11, targetCode)
	end
	local width = if gate.kind == 12 then 32 else true
	local offset = band(low, UINT16) + (if width == 32 then band(high, 0xFFFF0000) else 0)
	if offset > target.limit then
		fault(13, 0)
	end

	if call and not target.conforming and target.dpl < self.cpl then
		local tr = self.tr
		if not tr then
			fault(10, 0)
		end
		local slot = if tr.big then 4 + target.dpl * 8 else 2 + target.dpl * 4
		local pointerSize = if tr.big then 4 else 2
		if slot + pointerSize + 1 > tr.limit then
			fault(10, band(tr.selector, 0xFFFC))
		end
		local pointer = self:readLinear(tr.base + slot, pointerSize, true)
		local ss = self:readLinear(tr.base + slot + pointerSize, 2, true)
		local stackCode = band(ss, 0xFFFC)
		local stack = if stackCode ~= 0 then self:descriptor(ss, true) else nil
		if not stack or not stack.writable or stack.dpl ~= target.dpl or band(ss, 3) ~= target.dpl then
			fault(10, stackCode)
		end
		if not stack.present then
			fault(12, stackCode)
		end

		local oldStack, oldPointer = self.s[SS], self.r[5]
		local size = widthBytes(width)
		local words = { self.ip, self:selector(CS) }
		for index = 0, band(high, 31) - 1 do
			words[#words + 1] = self:read(oldStack, stackOffset(oldStack, oldPointer + index * size), width)
		end
		words[#words + 1] = oldPointer
		words[#words + 1] = self:selector(SS)
		local newPointer = stackOffset(stack, pointer - #words * size)
		for index, word in words do
			local address =
				self:segmentAddress(stack, stackOffset(stack, newPointer + (index - 1) * size), size, true, true)
			self:writeLinear(address, size, word, true)
		end
		self.cpl, self.s[SS], self.r[5] = target.dpl, stack, newPointer
	elseif call then
		self:push(self:selector(CS), width)
		self:push(self.ip, width)
	end
	self:enterCodeSegment(target, offset)
end

function Cpu:farReturn(width, discard)
	if not self:protected() or self:virtual8086() then
		return Cpu8088.farReturn(self, width, discard)
	end
	local stack, pointer = self.s[SS], self.r[5]
	local size = widthBytes(width)
	local ip = self:read(stack, stackOffset(stack, pointer), width)
	local cs = band(self:read(stack, stackOffset(stack, pointer + size), width), UINT16)
	local level, code = band(cs, 3), band(cs, 0xFFFC)
	if code == 0 or level < self.cpl then
		fault(13, code)
	end
	local target = self:descriptor(cs)
	if
		not target.executable
		or (target.conforming and target.dpl > level)
		or (not target.conforming and target.dpl ~= level)
	then
		fault(13, code)
	end
	if not target.present then
		fault(11, code)
	end
	if ip > target.limit then
		fault(13, 0)
	end
	local consumed = 2 * size + discard
	if level > self.cpl then
		local oldPointer = self:read(stack, stackOffset(stack, pointer + consumed), width)
		local ss = band(self:read(stack, stackOffset(stack, pointer + consumed + size), width), UINT16)
		local stackCode = band(ss, 0xFFFC)
		if stackCode == 0 or band(ss, 3) ~= level then
			fault(13, stackCode)
		end
		local oldStack = self:descriptor(ss)
		if not oldStack.writable or oldStack.dpl ~= level then
			fault(13, stackCode)
		end
		if not oldStack.present then
			fault(12, stackCode)
		end
		self.cpl, self.s[SS], self.r[5] = level, oldStack, oldPointer
		self:adjustStack(discard)
		self:clearOuterSegments(level)
	else
		self:adjustStack(consumed)
	end
	self:enterCodeSegment(target, ip)
end

function Cpu:farTransfer(selector, offset, width, call)
	if not self:protected() or self:virtual8086() then
		return Cpu8088.farTransfer(self, selector, offset, width, call)
	end
	local code, rpl = band(selector, 0xFFFC), band(selector, 3)
	if code == 0 then
		fault(13, 0)
	end
	local target = self:descriptor(selector)
	if target.system and (target.kind == 4 or target.kind == 12) then
		return self:transferThroughCallGate(target, call)
	end
	if target.system and target.kind == 9 then
		if math.max(self.cpl, rpl) > target.dpl then
			fault(13, code)
		end
		self:taskSwitch(selector, call and "call" or "jump")
		return
	end
	local level = self.cpl
	if
		not target.executable
		or target.dpl > level
		or (not target.conforming and (target.dpl ~= level or rpl > level))
	then
		fault(13, code)
	end
	if not target.present then
		fault(11, code)
	end
	if offset > target.limit then
		fault(13, 0)
	end
	-- A missing code segment can be loaded by the guest fault handler.
	-- Leave the caller's stack intact so the far call can be retried.
	if call then
		self:push(self:selector(CS), width)
		self:push(self.ip, width)
	end
	self:enterCodeSegment(target, offset)
end

function Cpu:iret(width)
	if self:virtual8086() then
		if self.cpl > extract(self.flags, 12, 2) then
			fault(13, 0)
		end
		local ip, cs, flags = self:pop(width), band(self:pop(width), UINT16), self:pop(width)
		self:restoreFlags(flags, width)
		self:loadSegment(CS, cs)
		if ip > self.s[CS].limit then
			fault(13, 0)
		end
		self.ip = ip
		return
	end
	if self:protected() and band(self.flags, 0x4000) ~= 0 then
		if not self.tr then
			fault(10, 0)
		end
		self:taskSwitch(self:readLinear(self.tr.base, 2, true), "return")
		return
	end
	local ip, cs, flags = self:pop(width), band(self:pop(width), UINT16), self:pop(width)
	if width == 32 and self.cpl == 0 and band(flags, VM) ~= 0 then
		local stack, ss = self:pop(32), band(self:pop(32), UINT16)
		local es, ds, fs, gs =
			band(self:pop(32), UINT16),
			band(self:pop(32), UINT16),
			band(self:pop(32), UINT16),
			band(self:pop(32), UINT16)
		self:restoreFlags(flags, width, true)
		self.cpl = 3
		self:loadSegment(CS, cs)
		self:loadSegment(SS, ss)
		self:loadSegment(ES, es)
		self:loadSegment(DS, ds)
		self:loadSegment(FS, fs)
		self:loadSegment(GS, gs)
		self.r[5] = stack
		if ip > self.s[CS].limit then
			fault(13, 0)
		end
		self.ip = ip
		return
	end
	if self:protected() then
		local level = band(cs, 3)
		if level < self.cpl then
			fault(13, band(cs, 0xFFFC))
		end
		if level > self.cpl then
			local stack, ss = self:pop(width), self:pop(width)
			self:restoreFlags(flags, width)
			self.cpl = level
			self:loadSegment(CS, cs)
			self:loadSegment(SS, ss)
			self.r[5] = stack
			self:clearOuterSegments(level)
		else
			self:loadSegment(CS, cs)
			self:restoreFlags(flags, width)
		end
	else
		self:loadSegment(CS, cs)
		self:restoreFlags(flags, width)
	end
	if ip > self.s[CS].limit then
		fault(13, 0)
	end
	self.ip = ip
end

function Cpu:finishFault(result, ip, code)
	if type(result) ~= "table" or result.vector == nil then
		error(result, 0)
	end
	local trace = self.opcodeTrace
	if trace then
		trace.faultVector, trace.faultCS, trace.faultIP = result.vector, code.selector, ip
	end
	self.ip, self.s[CS] = ip, code
	self.codeMask = code.big and UINT32 or UINT16
	local delivered, reason = pcall(self.interrupt, self, result.vector, false, result.code)
	if not delivered then
		error(
			string.format(
				"386 fault #%d could not be delivered at %04X:%08X (%s)",
				result.vector,
				code.selector,
				ip,
				type(reason) == "table" and ("fault #" .. reason.vector) or tostring(reason)
			),
			0
		)
	end
end

function Cpu:step(repeatLimit)
	local ip, code = self.ip, self.s[CS]
	local ok, result = pcall(Cpu8088.step, self, repeatLimit)
	if ok then
		return result
	end
	self:finishFault(result, ip, code)
end

-- The machine's slice is already protected. Keep the start of each
-- instruction available so a guest fault can be delivered at the same IP.
function Cpu:stepInSlice(repeatLimit)
	self.faultIp, self.faultCode = self.ip, self.s[CS]
	local result = Cpu8088.step(self, repeatLimit)
	self.faultCode = nil
	return result
end

local function multiply(a, b)
	local low = band(a, UINT16) * band(b, UINT16)
	local middle = shiftRight(a, 16) * band(b, UINT16) + band(a, UINT16) * shiftRight(b, 16) + math.floor(low / 0x10000)
	local high = shiftRight(a, 16) * shiftRight(b, 16) + math.floor(middle / 0x10000)
	return high, band(low, UINT16) + band(middle, UINT16) * 0x10000
end

local function multiplySigned(a, b)
	local high, low = multiply(a, b)
	if a >= 0x80000000 then
		high -= b
	end
	if b >= 0x80000000 then
		high -= a
	end
	return band(high, UINT32), low
end

local function negatePair(high, low)
	return band(-high - (low == 0 and 0 or 1), UINT32), band(-low, UINT32)
end

function Cpu:divideError()
	fault(0)
end

function Cpu:checkFpu(wait)
	local cr0 = self.control[0]
	if (wait and band(cr0, 10) == 10) or (not wait and band(cr0, 12) ~= 0) then
		fault(7)
	end
end

function Cpu:checkHalt()
	if self.cpl > 0 then
		fault(13, 0)
	end
end

function Cpu:checkInterruptFlag()
	if self.cpl > extract(self.flags, 12, 2) then
		fault(13, 0)
	end
end

function Cpu:checkPort(port, width)
	if self:virtual8086() and extract(self.flags, 12, 2) ~= 3 then
		fault(13, 0)
	end
	if self.cpl <= extract(self.flags, 12, 2) then
		return
	end
	local tr = self.tr
	if not tr or not tr.big or tr.limit < 103 then
		fault(13, 0)
	end
	local bitmap = self:readLinear(tr.base + 102, 2, true)
	for offset = 0, widthBytes(width) - 1 do
		local index = band(port + offset, UINT16)
		local byte = bitmap + shiftRight(index, 3)
		if byte > tr.limit or extract(self:readLinear(tr.base + byte, 1, true), band(index, 7)) ~= 0 then
			fault(13, 0)
		end
	end
end

function Cpu:portInstruction(opcode, port, width)
	self:checkPort(port, width)
	local size = widthBytes(width)
	if band(opcode, 2) == 0 then
		self:setRegister(0, width, self.bus:readIo(port, size))
	else
		self.bus:writeIo(port, self:getRegister(0, width), size)
	end
end

function Cpu:multiplyDivide(operation, value, width)
	if width ~= 32 then
		return Cpu8088.multiplyDivide(self, operation, value, width)
	end
	local high, low = self.r[3], self.r[1]
	if operation == 4 or operation == 5 then
		local fits
		if operation == 4 then
			high, low = multiply(low, value)
			fits = high == 0
		else
			high, low = multiplySigned(low, value)
			fits = high == (low >= 0x80000000 and UINT32 or 0)
		end
		self.flags = bor(band(self.flags, bnot(CF + OF)), fits and 0 or CF + OF)
		self.r[1], self.r[3] = low, high
		return
	end
	local negativeDividend, negativeDivisor = false, false
	if operation == 7 then
		negativeDividend, negativeDivisor = high >= 0x80000000, value >= 0x80000000
		if negativeDividend then
			high, low = negatePair(high, low)
		end
		if negativeDivisor then
			value = 0x100000000 - value
		end
	end
	if value == 0 or high >= value then
		fault(0)
	end
	local quotient = 0
	for index = 31, 0, -1 do
		high = high * 2 + extract(low, index)
		quotient *= 2
		if high >= value then
			high -= value
			quotient += 1
		end
	end
	if operation == 7 then
		local negative = negativeDividend ~= negativeDivisor
		if quotient > (negative and 0x80000000 or 0x7FFFFFFF) then
			fault(0)
		end
		quotient = negative and band(-quotient, UINT32) or quotient
		high = negativeDividend and band(-high, UINT32) or high
	end
	self.r[1], self.r[3] = quotient, high
end

function Cpu:imul(register, a, b, width)
	local fits, result
	if width == 32 then
		local high, low = multiplySigned(a, b)
		result = low
		fits = high == (low >= 0x80000000 and UINT32 or 0)
	else
		local product = signed(a, 0x8000) * signed(b, 0x8000)
		result = product
		fits = product >= -0x8000 and product < 0x8000
	end
	self:setRegister(register, width, result)
	self.flags = bor(band(self.flags, bnot(CF + OF)), fits and 0 or CF + OF)
end

function Cpu:additionalOpcode(opcode, width, override, startIp, repeatPrefix, repeatLimit)
	if opcode == 0x63 then -- ARPL
		if not self:protected() or self:virtual8086() then
			fault(6)
		end
		local register, operand, segment = self:decodeOperand(override)
		local destination = self:readOperand(operand, segment, true)
		local source = self:getRegister(register, true)
		local adjusted = band(destination, 3) < band(source, 3)
		self.flags = band(self.flags, bnot(ZF))
		if adjusted then
			self:writeOperand(operand, segment, true, band(destination, 0xFFFC) + band(source, 3))
			self.flags = bor(self.flags, ZF)
		end
	elseif opcode == 0x60 then -- PUSHA
		local stack = self:getRegister(4, width)
		for register = 0, 7 do
			self:push(register == 4 and stack or self:getRegister(register, width), width)
		end
	elseif opcode == 0x61 then -- POPA
		for register = 7, 0, -1 do
			if register == 4 then
				self:adjustStack(widthBytes(width))
			else
				self:setRegister(register, width, self:pop(width))
			end
		end
	elseif opcode == 0x68 or opcode == 0x6A then
		local value = opcode == 0x68 and self:fetch(width) or signed(self:fetch8(), 0x80)
		self:push(value, width)
	elseif opcode == 0x69 or opcode == 0x6B then
		local register, operand, segment = self:decodeOperand(override)
		local value = self:readOperand(operand, segment, width)
		local immediate = opcode == 0x69 and self:fetch(width) or band(signed(self:fetch8(), 0x80), widthMask(width))
		self:imul(register, value, immediate, width)
	elseif opcode >= 0x6C and opcode <= 0x6F then -- INS / OUTS
		local addressWidth = self.addressMask == UINT32 and 32 or true
		local count = self:getRegister(1, addressWidth)
		if repeatPrefix and count == 0 then
			return
		end
		local port = self:getRegister(2, true)
		local opWidth = band(opcode, 1) ~= 0 and width
		local size = widthBytes(opWidth)
		local delta = band(self.flags, DF) ~= 0 and -size or size
		local input = opcode < 0x6E
		local reg = input and 7 or 6
		local index = self:getRegister(reg, addressWidth)
		local segment = input and self.s[ES] or self.s[override or DS]
		self:checkPort(port, opWidth)
		local iterations = 0
		if
			repeatPrefix
			and opcode == 0x6D
			and delta > 0
			and repeatLimit
			and repeatLimit > 1
			and band(self.control[0], PG) == 0
		then
			local limit = repeatIterations(self, count, repeatLimit, true)
			if limit > 1 then
				local length = limit * size
				local address = segment.writable ~= false and repeatAddress(self, segment, index, length)
				local target = address and self.bus:ramSpan(address, length)
				if target and repeatCodeIsSafe(self, startIp, target, length) then
					iterations = self.bus:readIdeBlock(port, target, limit, size)
				end
			end
		end
		if iterations == 0 then
			iterations = 1
			if input then
				self:write(segment, index, opWidth, self.bus:readIo(port, size))
			else
				self.bus:writeIo(port, self:read(segment, index, opWidth), size)
			end
		end
		self:setRegister(reg, addressWidth, index + delta * iterations)
		if repeatPrefix then
			self:setRegister(1, addressWidth, count - iterations)
			if count > iterations then
				self.ip = startIp
			end
		end
		return iterations
	elseif opcode == 0x8F then -- POP r/m
		local stack = self.s[SS]
		local stackWidth = stack.big and 32 or true
		local size = widthBytes(width)
		local oldStack = self:getRegister(4, stackWidth)
		local newStack = band(oldStack + size, widthMask(stackWidth))
		-- An ESP-relative destination is evaluated after the stack increment.
		local operation, operand, segment = self:decodeOperand(override, newStack - oldStack)
		if operation ~= 0 then
			fault(6)
		end
		local value = self:read(stack, oldStack, width)
		if segment then
			self:write(segment, operand, width, value)
			self:setRegister(4, stackWidth, newStack)
		else
			self:setRegister(4, stackWidth, newStack)
			self:setRegister(operand, width, value)
		end
	elseif opcode == 0xC0 or opcode == 0xC1 then
		local operation, operand, segment = self:decodeOperand(override)
		local count = band(self:fetch8(), 31)
		local opWidth = opcode == 0xC1 and width
		if count > 0 then
			local value = self:readOperand(operand, segment, opWidth)
			self:writeOperand(operand, segment, opWidth, self:shift(operation, value, opWidth, count))
		end
	elseif opcode == 0xC8 then -- ENTER
		local allocation, depth = self:fetch(true), band(self:fetch8(), 31)
		local frame = self:getRegister(5, width)
		self:push(frame, width)
		local stackWidth = self.s[SS].big and 32 or true
		local frameBase = self:getRegister(4, stackWidth)
		for _ = 2, depth do
			frame = band(frame - widthBytes(width), widthMask(stackWidth))
			self:push(self:read(self.s[SS], frame, width), width)
		end
		if depth > 0 then
			self:push(frameBase, width)
		end
		self:setRegister(5, width, frameBase)
		self:adjustStack(-allocation)
	elseif opcode == 0xC9 then -- LEAVE
		local stackWidth = self.s[SS].big and 32 or true
		self:setRegister(4, stackWidth, self:getRegister(5, stackWidth))
		self:setRegister(5, width, self:pop(width))
	end
end

function Cpu:extendedOpcode(opcode, width, override)
	if opcode >= 0x80 and opcode <= 0x8F then
		local offset = self:fetch(width)
		if self:condition(band(opcode, 15)) then
			self.ip = band(self.ip + offset, widthMask(width))
		end
	elseif opcode >= 0x90 and opcode <= 0x9F then
		local _, operand, segment = self:decodeOperand(override)
		self:writeOperand(operand, segment, false, self:condition(band(opcode, 15)) and 1 or 0)
	elseif opcode == 0x00 then
		local operation, operand, segment = self:decodeOperand(override)
		if not self:protected() then
			fault(6)
		end
		if operation == 0 or operation == 1 then -- SLDT / STR
			local system = if operation == 0 then self.ldt else self.tr
			self:writeOperand(operand, segment, true, system and system.selector or 0)
		elseif operation == 2 or operation == 3 then -- LLDT / LTR
			if self.cpl ~= 0 then
				fault(13, 0)
			end
			local selector = self:readOperand(operand, segment, true)
			local code = band(selector, 0xFFFC)
			if operation == 2 and code == 0 then
				self.ldt = nil
				return
			end
			if band(selector, 4) ~= 0 or code == 0 then
				fault(13, code)
			end
			local descriptor = self:descriptor(selector)
			if
				not descriptor.system
				or (operation == 2 and descriptor.kind ~= 2)
				or (operation == 3 and descriptor.kind ~= 1 and descriptor.kind ~= 9)
			then
				fault(13, code)
			end
			if not descriptor.present then
				fault(11, code)
			end
			if operation == 2 then
				self.ldt = descriptor
			else
				descriptor.big = descriptor.kind == 9
				self.tr = descriptor
				local accessAddress = descriptor.address + 5
				self:writeLinear(accessAddress, 1, bor(self:readLinear(accessAddress, 1, true), 2))
			end
		elseif operation == 4 or operation == 5 then -- VERR / VERW
			local selector = self:readOperand(operand, segment, true)
			local target = if band(selector, 0xFFFC) ~= 0 then self:descriptor(selector, true) else nil
			local valid = target
				and not target.system
				and (target.conforming or target.dpl >= math.max(self.cpl, band(selector, 3)))
				and (if operation == 4 then target.readable else target.writable)
			self.flags = bor(band(self.flags, bnot(ZF)), if valid then ZF else 0)
		else
			fault(6)
		end
	elseif opcode == 0x01 then
		local operation, operand, segment = self:decodeOperand(override)
		if operation <= 3 then
			if segment == nil then
				fault(6)
			end
			if operation >= 2 and self.cpl ~= 0 then
				fault(13, 0)
			end
			local address = self:segmentAddress(segment, operand, 6, operation < 2, segment == self.s[SS])
			local table = operation % 2 == 0 and self.gdt or self.idt
			if operation < 2 then
				self:writeLinear(address, 2, table.limit)
				self:writeLinear(address + 2, 4, table.base)
			else
				local limit = self:readLinear(address, 2)
				local base = self:readLinear(address + 2, 4)
				table.limit = limit
				table.base = width == 32 and base or band(base, 0xFFFFFF)
			end
		elseif operation == 4 then -- SMSW
			self:writeOperand(operand, segment, true, self.control[0])
		elseif operation == 6 then -- LMSW
			if self.cpl ~= 0 then
				fault(13, 0)
			end
			local value = self:readOperand(operand, segment, true)
			self.control[0] = bor(band(self.control[0], 0xFFFFFFF1), band(value, 15))
		else
			fault(6)
		end
	elseif opcode == 0x02 or opcode == 0x03 then -- LAR / LSL
		if not self:protected() then
			fault(6)
		end
		local register, operand, segment = self:decodeOperand(override)
		local selector = self:readOperand(operand, segment, true)
		local descriptor = band(selector, 0xFFFC) ~= 0 and self:descriptor(selector, true)
		self.flags = band(self.flags, bnot(ZF))
		if descriptor and (descriptor.conforming or math.max(self.cpl, band(selector, 3)) <= descriptor.dpl) then
			local kind = descriptor.kind
			local valid = if opcode == 0x02
				then kind ~= 0 and kind ~= 8 and kind ~= 10 and kind ~= 13
				else kind == 1 or kind == 2 or kind == 3 or kind == 9 or kind == 11
			if not descriptor.system or valid then
				self.flags = bor(self.flags, ZF)
				self:setRegister(register, width, opcode == 0x02 and descriptor.accessRights or descriptor.limit)
			end
		end
	elseif opcode == 0x06 then -- CLTS
		if self.cpl ~= 0 then
			fault(13, 0)
		end
		self.control[0] = band(self.control[0], 0xFFFFFFF7)
	elseif opcode == 0x20 or opcode == 0x22 then
		local control, register, segment = self:decodeOperand(nil)
		if segment ~= nil or self.control[control] == nil then
			fault(6)
		end
		if self.cpl ~= 0 then
			fault(13, 0)
		end
		if opcode == 0x20 then
			self:setRegister(register, 32, self.control[control])
		else
			local value = self:getRegister(register, 32)
			if control == 0 then
				if band(value, PG) ~= 0 and band(value, PE) == 0 then
					fault(13, 0)
				end
				value = bor(band(value, 0x8000001F), 0x10)
			end
			self.control[control] = value
		end
	elseif opcode == 0x21 or opcode == 0x23 then
		local register, operand, segment = self:decodeOperand(nil)
		if segment ~= nil then
			fault(6)
		end
		if self.cpl ~= 0 then
			fault(13, 0)
		end
		if register == 4 or register == 5 then
			register += 2
		end
		if opcode == 0x21 then
			self:setRegister(operand, 32, self.debugRegisters[register])
		else
			self.debugRegisters[register] = self:getRegister(operand, 32)
		end
	elseif opcode == 0xA0 or opcode == 0xA1 or opcode == 0xA8 or opcode == 0xA9 then
		local segment = opcode < 0xA8 and FS or GS
		if band(opcode, 1) == 0 then
			self:push(self:selector(segment), width)
		else
			self:loadSegment(segment, self:pop(width))
		end
	elseif opcode == 0xA4 or opcode == 0xA5 or opcode == 0xAC or opcode == 0xAD then -- SHLD / SHRD
		local register, operand, segment = self:decodeOperand(override)
		local count = band(band(opcode, 1) == 0 and self:fetch8() or self:getRegister(1, false), 31)
		local bits = widthBytes(width) * 8
		if count > 0 and count <= bits then
			local destination = self:readOperand(operand, segment, width)
			local source = self:getRegister(register, width)
			local result, carry
			if opcode < 0xAC then
				result = bor(bit32.lshift(destination, count), shiftRight(source, bits - count))
				carry = extract(destination, bits - count)
			else
				result = bor(shiftRight(destination, count), bit32.lshift(source, bits - count))
				carry = extract(destination, count - 1)
			end
			result = band(result, widthMask(width))
			local overflow = count == 1 and extract(result, bits - 1) ~= extract(destination, bits - 1)
			self:alu(1, result, 0, width)
			self.flags = bor(self.flags, carry, overflow and OF or 0)
			self:writeOperand(operand, segment, width, result)
		end
	elseif opcode == 0xA3 or opcode == 0xAB or opcode == 0xB3 or opcode == 0xBB or opcode == 0xBA then
		local register, operand, segment = self:decodeOperand(override)
		local bits = widthBytes(width) * 8
		local operation = extract(opcode, 3, 2)
		local index
		if opcode == 0xBA then
			if register < 4 then
				fault(6)
			end
			operation = register - 4
			index = self:fetch8()
		else
			index = self:getRegister(register, width)
			if segment then
				index = signed(index, 2 ^ (bits - 1))
				operand = band(operand + math.floor(index / bits) * widthBytes(width), self.addressMask)
			end
		end
		local selected = bit32.lshift(1, index % bits)
		local value = self:readOperand(operand, segment, width)
		self.flags = bor(band(self.flags, bnot(CF)), band(value, selected) == 0 and 0 or CF)
		if operation ~= 0 then
			local result = operation == 1 and bor(value, selected)
				or (operation == 2 and band(value, bnot(selected)) or bit32.bxor(value, selected))
			self:writeOperand(operand, segment, width, result)
		end
	elseif opcode == 0xAF then
		local register, operand, segment = self:decodeOperand(override)
		self:imul(register, self:getRegister(register, width), self:readOperand(operand, segment, width), width)
	elseif opcode == 0xB2 or opcode == 0xB4 or opcode == 0xB5 then -- LSS / LFS / LGS
		local register, operand, segment = self:decodeOperand(override)
		if segment == nil then
			fault(6)
		end
		local value = self:read(segment, operand, width)
		local selector = self:read(segment, operand + widthBytes(width), true)
		self:loadSegment(opcode == 0xB2 and SS or (opcode == 0xB4 and FS or GS), selector)
		self:setRegister(register, width, value)
	elseif opcode == 0xB6 or opcode == 0xB7 or opcode == 0xBE or opcode == 0xBF then
		local register, operand, segment = self:decodeOperand(override)
		local sourceWidth = band(opcode, 1) ~= 0
		local value = self:readOperand(operand, segment, sourceWidth)
		if opcode >= 0xBE then
			value = signed(value, sourceWidth and 0x8000 or 0x80)
		end
		self:setRegister(register, width, value)
	elseif opcode == 0xBC or opcode == 0xBD then -- BSF / BSR
		local register, operand, segment = self:decodeOperand(override)
		local value = self:readOperand(operand, segment, width)
		self.flags = bor(band(self.flags, bnot(ZF)), value == 0 and ZF or 0)
		if value ~= 0 then
			self:setRegister(register, width, opcode == 0xBC and bit32.countrz(value) or 31 - bit32.countlz(value))
		end
	elseif self.bus.pc and opcode >= 0xC8 and opcode <= 0xCF then -- BSWAP
		local register = opcode - 0xC8
		local value = self:getRegister(register, 32)
		self:setRegister(register, 32, bit32.byteswap(value))
	elseif self.bus.pc and (opcode == 0x08 or opcode == 0x09) then -- INVD / WBINVD
		if self.cpl ~= 0 then
			fault(13, 0)
		end
		-- There is no guest CPU cache to flush.
	elseif opcode == 0xFF then -- Reserved encoding
		fault(6)
	else
		fault(6)
	end
end

return Cpu
