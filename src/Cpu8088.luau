--!optimize 2

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor

local AX, CX, DX, SP, SI, DI = 1, 2, 3, 5, 7, 8
local ES, CS, SS, DS = 1, 2, 3, 4
local CF, PF, AF, ZF, SF = 0x001, 0x004, 0x010, 0x040, 0x080
local TF, IF, DF, OF = 0x100, 0x200, 0x400, 0x800

local Cpu = {}
Cpu.__index = Cpu

local function widthMask(wide)
	return wide == 32 and 0xFFFFFFFF or (wide and 0xFFFF or 0xFF)
end

local function widthBytes(wide)
	return wide == 32 and 4 or (wide and 2 or 1)
end

local function signed(value, sign)
	return value < sign and value or value - sign * 2
end

local function signed8(value)
	return signed(value, 0x80)
end

function Cpu.new(bus)
	return setmetatable({
		bus = bus,
		r = { 0, 0, 0, 0, 0, 0, 0, 0 }, -- AX CX DX BX SP BP SI DI
		s = { 0, 0xFFFF, 0, 0 }, -- ES CS SS DS
		ip = 0,
		flags = 0xF002,
		halted = false,
		interruptShadow = false,
		opcodeTrace = false,
		codeMask = 0xFFFF,
		addressMask = 0xFFFF,
	}, Cpu)
end

function Cpu:selector(index)
	return self.s[index]
end

function Cpu:loadSegment(index, selector)
	self.s[index] = band(selector, 0xFFFF)
end

function Cpu:farTransfer(selector, offset, width, call)
	if call then
		self:push(self:selector(CS), width)
		self:push(self.ip, width)
	end
	self:loadSegment(CS, selector)
	self.ip = offset
end

function Cpu:farReturn(width, discard)
	self.ip = self:pop(width)
	self:loadSegment(CS, self:pop(width))
	self:adjustStack(discard)
end

function Cpu:restoreFlags(value)
	self.flags = bor(band(value, 0x0FD5), 0xF002)
end

function Cpu:iret()
	self.ip = self:pop()
	self:loadSegment(CS, self:pop())
	self:restoreFlags(self:pop())
end

function Cpu:read(segment, offset, wide)
	local base = segment * 16
	local low = self.bus:read8(base + offset)
	if wide then
		return low + self.bus:read8(base + band(offset + 1, 0xFFFF)) * 256
	end
	return low
end

function Cpu:write(segment, offset, wide, value)
	local base = segment * 16
	self.bus:write8(base + offset, value)
	if wide then
		self.bus:write8(base + band(offset + 1, 0xFFFF), bit32.rshift(value, 8))
	end
end

function Cpu:fetch8()
	local value = self:read(self.s[CS], self.ip, false)
	self.ip = band(self.ip + 1, self.codeMask)
	return value
end

function Cpu:fetch(wide)
	local low = self:fetch8()
	if wide then
		low += self:fetch8() * 256
		if wide == 32 then
			low += self:fetch8() * 0x10000 + self:fetch8() * 0x1000000
		end
	end
	return low
end

function Cpu:push(value)
	self.r[SP] = band(self.r[SP] - 2, 0xFFFF)
	self:write(self.s[SS], self.r[SP], true, value)
end

function Cpu:pop()
	local value = self:read(self.s[SS], self.r[SP], true)
	self.r[SP] = band(self.r[SP] + 2, 0xFFFF)
	return value
end

function Cpu:adjustStack(discard)
	self.r[SP] = band(self.r[SP] + discard, 0xFFFF)
end

function Cpu:canInterrupt()
	return not self.interruptShadow and band(self.flags, IF) ~= 0
end

function Cpu:interrupt(vector)
	self:push(self.flags)
	self:push(self.s[CS])
	self:push(self.ip)
	self.flags = band(self.flags, bit32.bnot(IF + TF))
	self.ip = self:read(0, vector * 4, true)
	self.s[CS] = self:read(0, vector * 4 + 2, true)
	self.halted = false
	self.interruptShadow = false
end

function Cpu:getRegister(index, wide)
	if wide then
		return self.r[index + 1]
	end
	local word = self.r[band(index, 3) + 1]
	return band(index < 4 and word or bit32.rshift(word, 8), 0xFF)
end

function Cpu:setRegister(index, wide, value)
	if wide then
		self.r[index + 1] = band(value, 0xFFFF)
	else
		local slot = band(index, 3) + 1
		local byte = band(value, 0xFF)
		if index < 4 then
			self.r[slot] = bor(band(self.r[slot], 0xFF00), byte)
		else
			self.r[slot] = bor(band(self.r[slot], 0x00FF), byte * 256)
		end
	end
end

local EFFECTIVE_ADDRESS = {
	{ 4, 7 }, -- BX + SI
	{ 4, 8 }, -- BX + DI
	{ 6, 7 }, -- BP + SI
	{ 6, 8 }, -- BP + DI
	{ 7 },
	{ 8 },
	{ 6 },
	{ 4 },
}

function Cpu:decodeOperand(override)
	local modrm = self:fetch8()
	local mode = bit32.rshift(modrm, 6)
	local register = band(bit32.rshift(modrm, 3), 7)
	local operand = band(modrm, 7)
	if mode == 3 then
		return register, operand, nil
	end
	if mode == 0 and operand == 6 then
		return register, self:fetch(true), self.s[override or DS]
	end
	local pair = EFFECTIVE_ADDRESS[operand + 1]
	local base = self.r[pair[1]] + (pair[2] and self.r[pair[2]] or 0)
	if mode == 1 then
		base += signed8(self:fetch8())
	elseif mode == 2 then
		base += self:fetch(true)
	end
	return register, band(base, 0xFFFF), self.s[override or (pair[1] == 6 and SS or DS)]
end

function Cpu:readOperand(operand, segment, wide)
	if segment ~= nil then
		return self:read(segment, operand, wide)
	end
	return self:getRegister(operand, wide)
end

function Cpu:writeOperand(operand, segment, wide, value)
	if segment ~= nil then
		self:write(segment, operand, wide, value)
	else
		self:setRegister(operand, wide, value)
	end
end

local parityFlags = table.create(256)
for byte = 0, 255 do
	local parity = bxor(byte, bit32.rshift(byte, 4))
	parity = bxor(parity, bit32.rshift(parity, 2))
	parity = bxor(parity, bit32.rshift(parity, 1))
	parityFlags[byte] = if band(parity, 1) == 0 then PF else 0
end

local function resultFlags(result, sign)
	return parityFlags[band(result, 0xFF)] + (result == 0 and ZF or 0) + (band(result, sign) ~= 0 and SF or 0)
end

function Cpu:alu(operation, a, b, wide)
	local mask = widthMask(wide)
	local sign = (mask + 1) / 2
	local carry = band(self.flags, CF)
	local result, extra = 0, 0

	if operation == 1 then -- OR
		result = bor(a, b)
	elseif operation == 4 then -- AND
		result = band(a, b)
	elseif operation == 6 then -- XOR
		result = bxor(a, b)
	else
		local raw, overflow
		if operation == 0 or operation == 2 then -- ADD, ADC
			raw = a + b + (operation == 2 and carry or 0)
			overflow = band(bit32.bnot(bxor(a, b)), bxor(a, raw), sign) ~= 0
		else -- SBB, SUB, CMP
			raw = a - b - (operation == 3 and carry or 0)
			overflow = band(bxor(a, b), bxor(a, raw), sign) ~= 0
		end
		result = band(raw, mask)
		extra = (raw < 0 or raw > mask) and CF or 0
		extra += overflow and OF or 0
		extra += band(bxor(a, b, result), 0x10) ~= 0 and AF or 0
	end

	self.flags = bor(band(self.flags, bit32.bnot(CF + PF + AF + ZF + SF + OF)), extra, resultFlags(result, sign))
	return result
end

local conditionMasks = {}
local conditionFlags = CF + PF + ZF + SF + OF
for combination = 0, 31 do
	local flags = 0
	for bit, flag in { CF, PF, ZF, SF, OF } do
		if bit32.extract(combination, bit - 1) ~= 0 then
			flags += flag
		end
	end
	local carry = band(flags, CF) ~= 0
	local zero = band(flags, ZF) ~= 0
	local sign = band(flags, SF) ~= 0
	local overflow = band(flags, OF) ~= 0
	local signedLess = sign ~= overflow
	local conditions =
		{ overflow, carry, zero, carry or zero, sign, band(flags, PF) ~= 0, signedLess, zero or signedLess }
	local mask = 0
	for group, value in conditions do
		mask += bit32.lshift(1, (group - 1) * 2 + (value and 0 or 1))
	end
	conditionMasks[flags] = mask
end

function Cpu:condition(code)
	return bit32.extract(conditionMasks[band(self.flags, conditionFlags)], code) ~= 0
end

function Cpu:shift(operation, value, wide, count)
	if count == 0 then
		return value
	end

	local mask = widthMask(wide)
	local sign = (mask + 1) / 2
	local original = value
	local carry = band(self.flags, CF)
	if operation >= 4 then
		-- Shift the whole count at once and recover the last bit shifted out.
		-- Width and count are independent on the 8088, so counts may exceed
		-- the operand size, including the host's 32-bit shift width.
		local bits = if wide == 32 then 32 elseif wide then 16 else 8
		if operation == 4 or operation == 6 then -- SHL / SAL
			carry = if count <= bits then bit32.extract(value, bits - count) else 0
			value = band(bit32.lshift(value, count), mask)
		elseif operation == 5 then -- SHR
			carry = if count <= bits then bit32.extract(value, count - 1) else 0
			value = bit32.rshift(value, count)
		else -- SAR
			carry = bit32.extract(value, math.min(count, bits) - 1)
			local extend = 32 - bits
			value = band(bit32.arshift(bit32.lshift(value, extend), count + extend), mask)
		end
	else
		for _ = 1, count do
			local high = value >= sign and 1 or 0
			local low = band(value, 1)
			if operation == 0 then -- ROL
				value, carry = band(value * 2 + high, mask), high
			elseif operation == 1 then -- ROR
				value, carry = bit32.rshift(value, 1) + low * sign, low
			elseif operation == 2 then -- RCL
				value, carry = band(value * 2 + carry, mask), high
			else -- RCR
				value, carry = bit32.rshift(value, 1) + carry * sign, low
			end
		end
	end

	self.flags = bor(band(self.flags, bit32.bnot(CF)), carry)
	if operation >= 4 then
		self.flags = bor(band(self.flags, bit32.bnot(PF + ZF + SF)), resultFlags(value, sign))
	end
	if count == 1 then
		local high = value >= sign and 1 or 0
		local overflow = false
		if operation == 1 or operation == 3 then
			overflow = high ~= (band(value, sign / 2) ~= 0 and 1 or 0)
		elseif operation == 5 then
			overflow = original >= sign
		elseif operation ~= 7 then
			overflow = high ~= carry
		end
		self.flags = bor(band(self.flags, bit32.bnot(OF)), overflow and OF or 0)
	end
	return value
end

function Cpu:divideError()
	self:interrupt(0)
end

function Cpu:multiplyDivide(operation, value, wide)
	local sign = wide and 0x8000 or 0x80
	local base = sign * 2
	local acc = self:getRegister(0, wide)
	if operation <= 5 then
		local product = operation == 4 and acc * value or signed(acc, sign) * signed(value, sign)
		local fits = operation == 4 and product < base or operation == 5 and product >= -sign and product < sign
		self:setRegister(0, true, product)
		if wide then
			self:setRegister(2, true, bit32.rshift(product, 16))
		end
		self.flags = bor(band(self.flags, bit32.bnot(CF + OF)), fits and 0 or CF + OF)
		return
	end

	local dividend = self:getRegister(0, true) + (wide and self:getRegister(2, true) * 0x10000 or 0)
	local minimum, maximum = 0, base - 1
	if operation == 7 then
		dividend = signed(dividend, base * base / 2)
		value = signed(value, sign)
		minimum, maximum = -sign, sign - 1
	end
	if value == 0 then
		self:divideError()
		return
	end
	local ratio = dividend / value
	local quotient = ratio < 0 and math.ceil(ratio) or math.floor(ratio)
	if quotient < minimum or quotient > maximum then
		self:divideError()
	else
		self:setRegister(0, wide, quotient)
		self:setRegister(wide and 2 or 4, wide, dividend - quotient * value)
	end
end

function Cpu:stringInstruction(opcode, segment, repeatPrefix, startIp, repeatLimit, wide)
	local addressSize = self.addressMask == 0xFFFFFFFF and 32 or true
	local count = self:getRegister(CX - 1, addressSize)
	local iterations = repeatPrefix and math.min(count, repeatLimit or 1) or 1
	local size = widthBytes(wide)
	local delta = band(self.flags, DF) == 0 and size or -size
	local kind = band(opcode, 0xFE)
	local compare = kind == 0xA6 or kind == 0xAE
	local es = self.s[ES]
	for iteration = 1, iterations do
		if kind == 0xA4 or kind == 0xA6 or kind == 0xAC then
			local index = self:getRegister(SI - 1, addressSize)
			local source = self:read(segment, index, wide)
			if kind == 0xA4 then
				self:write(es, self:getRegister(DI - 1, addressSize), wide, source)
			elseif kind == 0xA6 then
				self:alu(7, source, self:read(es, self:getRegister(DI - 1, addressSize), wide), wide)
			else
				self:setRegister(0, wide, source)
			end
			-- A fault on the destination must leave this iteration's indexes intact.
			self:setRegister(SI - 1, addressSize, index + delta)
		elseif kind == 0xAA then
			self:write(es, self:getRegister(DI - 1, addressSize), wide, self:getRegister(0, wide))
		else
			self:alu(7, self:getRegister(0, wide), self:read(es, self:getRegister(DI - 1, addressSize), wide), wide)
		end

		if kind ~= 0xAC then
			self:setRegister(DI - 1, addressSize, self:getRegister(DI - 1, addressSize) + delta)
		end
		if repeatPrefix then
			count -= 1
			self:setRegister(CX - 1, addressSize, count)
			local zero = band(self.flags, ZF) ~= 0
			if compare and zero ~= (repeatPrefix == 0xF3) then
				return iteration
			end
		end
	end
	if repeatPrefix and count ~= 0 then
		-- Re-enter at the prefix after a frame boundary or hardware interrupt.
		self.ip = startIp
	end
	return math.max(iterations, 1)
end

function Cpu:portInstruction(opcode, port, wide)
	local size = widthBytes(wide)
	if band(opcode, 2) == 0 then
		local value = 0
		for index = 0, size - 1 do
			value += self.bus:readPort(band(port + index, 0xFFFF)) * 256 ^ index
		end
		self:setRegister(0, wide, value)
	else
		local value = self.r[AX]
		for index = 0, size - 1 do
			self.bus:writePort(band(port + index, 0xFFFF), bit32.extract(value, index * 8, 8))
		end
	end
end

local PREFIX = {
	[0x26] = ES,
	[0x2E] = CS,
	[0x36] = SS,
	[0x3E] = DS,
	[0x64] = 5, -- FS
	[0x65] = 6, -- GS
	[0x66] = "operand",
	[0x67] = "address",
	[0xF0] = "lock",
	[0xF2] = "repeat",
	[0xF3] = "repeat",
}

-- The 386 decodes these separately because they extend or change 8088 instructions.
local ADDITIONAL_386 = {
	[0x60] = true,
	[0x61] = true,
	[0x63] = true,
	[0x68] = true,
	[0x69] = true,
	[0x6A] = true,
	[0x6B] = true,
	[0x6C] = true,
	[0x6D] = true,
	[0x6E] = true,
	[0x6F] = true,
	[0x8F] = true,
	[0xC0] = true,
	[0xC1] = true,
	[0xC8] = true,
	[0xC9] = true,
}

local function recordOpcode(cpu, trace, startIp, opcode, prefixCount)
	trace.opcode, trace.ip, trace.cs, trace.prefixCount = opcode, startIp, cpu:selector(CS), prefixCount
	trace.counts[opcode] = (trace.counts[opcode] or 0) + 1
	trace.decoded += 1
end

function Cpu:step(repeatLimit)
	if self.halted then
		return
	end

	self.interruptShadow = false
	local startIp = self.ip
	local trace = self.opcodeTrace
	local opcode = self:fetch8()
	local override, repeatPrefix, operandOverride, addressOverride
	local prefixCount = 0
	local prefix = PREFIX[opcode]
	while prefix do
		if opcode >= 0x64 and opcode <= 0x67 and not self.is386 then
			break
		end
		if type(prefix) == "number" then
			override = prefix
		elseif prefix == "repeat" then
			repeatPrefix = opcode
		elseif prefix == "operand" then
			operandOverride = true
		elseif prefix == "address" then
			addressOverride = true
		end
		prefixCount += 1
		if trace then
			trace.prefixes[prefixCount] = opcode
		end
		opcode = self:fetch8()
		if self.ip == startIp or (self.is386 and prefixCount >= 15) then
			error("Instruction contains too many prefixes", 0)
		end
		prefix = PREFIX[opcode]
	end

	if trace and (opcode ~= 0x0F or not self.is386) then
		recordOpcode(self, trace, startIp, opcode, prefixCount)
	end
	local code32 = self.codeMask == 0xFFFFFFFF
	local operandSize = code32 ~= (operandOverride == true) and 32 or true
	local addressSize = code32 ~= (addressOverride == true) and 32 or true
	self.addressMask = if addressSize == 32 then 0xFFFFFFFF else 0xFFFF
	local wide = band(opcode, 1) ~= 0 and operandSize
	local form = band(opcode, 7)

	if opcode >= 0x88 and opcode <= 0x8B then
		local register, operand, segment = self:decodeOperand(override)
		if band(opcode, 2) ~= 0 then
			self:setRegister(register, wide, self:readOperand(operand, segment, wide))
		else
			self:writeOperand(operand, segment, wide, self:getRegister(register, wide))
		end
	elseif opcode >= 0x70 and opcode <= 0x7F then
		local delta = signed8(self:fetch8())
		if self:condition(band(opcode, 15)) then
			self.ip = band(self.ip + delta, self.codeMask)
		end
	elseif opcode >= 0x80 and opcode <= 0x83 then
		local operation, operand, segment = self:decodeOperand(override)
		local immediate = self:fetch(opcode == 0x81 and operandSize)
		if opcode == 0x83 then
			immediate = band(signed8(immediate), widthMask(operandSize))
		end
		local result = self:alu(operation, self:readOperand(operand, segment, wide), immediate, wide)
		if operation ~= 7 then
			self:writeOperand(operand, segment, wide, result)
		end
	elseif opcode == 0x0F and self.is386 then
		local extended = self:fetch8()
		if trace then
			recordOpcode(self, trace, startIp, extended + 256, prefixCount)
		end
		self:extendedOpcode(extended, operandSize, override)
	elseif opcode < 0x40 and form <= 5 then
		local operation = bit32.rshift(opcode, 3)
		if form >= 4 then
			local result = self:alu(operation, self:getRegister(0, wide), self:fetch(wide), wide)
			if operation ~= 7 then
				self:setRegister(0, wide, result)
			end
		else
			local register, operand, segment = self:decodeOperand(override)
			local left = self:readOperand(operand, segment, wide)
			local right = self:getRegister(register, wide)
			local toRegister = band(opcode, 2) ~= 0
			if toRegister then
				left, right = right, left
			end
			local result = self:alu(operation, left, right, wide)
			if operation ~= 7 then
				if toRegister then
					self:setRegister(register, wide, result)
				else
					self:writeOperand(operand, segment, wide, result)
				end
			end
		end
	elseif opcode < 0x20 and form >= 6 then
		local segment = bit32.rshift(opcode, 3) + 1
		if form == 6 then
			self:push(self:selector(segment), operandSize)
		else
			self:loadSegment(segment, self:pop(operandSize))
			self.interruptShadow = segment == SS
		end
	elseif opcode == 0x27 or opcode == 0x2F then -- DAA / DAS
		local previous = self:getRegister(0, false)
		local carry = band(self.flags, CF) ~= 0
		local adjust = opcode == 0x27 and 1 or -1
		local al = previous
		local auxiliary = band(al, 15) > 9 or band(self.flags, AF) ~= 0
		local lowBorrow = auxiliary and opcode == 0x2F and al < 6
		if auxiliary then
			al += 6 * adjust
		end
		local high = previous > 0x99 or carry
		if high then
			al += 0x60 * adjust
		end
		al = band(al, 0xFF)
		self:setRegister(0, false, al)
		self.flags = bor(
			band(self.flags, bit32.bnot(CF + AF + PF + ZF + SF)),
			resultFlags(al, 0x80),
			(high or lowBorrow) and CF or 0,
			auxiliary and AF or 0
		)
	elseif opcode == 0x37 or opcode == 0x3F then -- AAA / AAS
		local al = self:getRegister(0, false)
		local adjust = band(al, 15) > 9 or band(self.flags, AF) ~= 0
		if adjust then
			self:setRegister(0, true, self:getRegister(0, true) + (opcode == 0x37 and 0x106 or -0x106))
		end
		self:setRegister(0, false, band(self.r[AX], 0xF))
		self.flags = bor(band(self.flags, bit32.bnot(CF + AF)), adjust and CF + AF or 0)
	elseif opcode >= 0x40 and opcode <= 0x4F then
		local register = band(opcode, 7)
		local carry = band(self.flags, CF)
		local result = self:alu(opcode < 0x48 and 0 or 5, self:getRegister(register, operandSize), 1, operandSize)
		self:setRegister(register, operandSize, result)
		self.flags = bor(band(self.flags, bit32.bnot(CF)), carry)
	elseif opcode >= 0x50 and opcode <= 0x57 then
		local register = band(opcode, 7)
		local value = self:getRegister(register, operandSize)
		-- On an 8088, PUSH SP stores the already decremented value.
		self:push(not self.is386 and register == SP - 1 and value - 2 or value, operandSize)
	elseif opcode >= 0x58 and opcode <= 0x5F then
		self:setRegister(band(opcode, 7), operandSize, self:pop(operandSize))
	elseif ADDITIONAL_386[opcode] and self.is386 then
		return self:additionalOpcode(opcode, operandSize, override, startIp, repeatPrefix, repeatLimit)
	elseif opcode >= 0x84 and opcode <= 0x87 then
		local register, operand, segment = self:decodeOperand(override)
		local left = self:readOperand(operand, segment, wide)
		local right = self:getRegister(register, wide)
		if opcode < 0x86 then
			self:alu(4, left, right, wide)
		else
			self:writeOperand(operand, segment, wide, right)
			self:setRegister(register, wide, left)
		end
	elseif opcode == 0x8C or opcode == 0x8E then
		local register, operand, segment = self:decodeOperand(override)
		if register > (self.is386 and 5 or 3) or (opcode == 0x8E and register == CS - 1) then
			if self.is386 then
				error({ vector = 6 }, 0)
			end
			error("Invalid segment register", 0)
		end
		if opcode == 0x8C then
			self:writeOperand(operand, segment, segment == nil and operandSize or true, self:selector(register + 1))
		else
			self:loadSegment(register + 1, self:readOperand(operand, segment, true))
			self.interruptShadow = register == SS - 1
		end
	elseif opcode == 0x8D or opcode == 0x8F then
		local register, operand, segment = self:decodeOperand(override)
		if opcode == 0x8D then
			assert(segment ~= nil, "LEA requires an effective address")
			self:setRegister(register, operandSize, operand)
		else
			assert(register == 0, "Invalid POP encoding")
			self:writeOperand(operand, segment, operandSize, self:pop(operandSize))
		end
	elseif opcode >= 0x90 and opcode <= 0x97 then
		local register = band(opcode, 7)
		local value = self:getRegister(register, operandSize)
		self:setRegister(register, operandSize, self:getRegister(0, operandSize))
		self:setRegister(0, operandSize, value)
	elseif opcode == 0x98 then
		local sourceSize = operandSize == 32
		local sign = sourceSize and 0x8000 or 0x80
		self:setRegister(0, operandSize, signed(self:getRegister(0, sourceSize), sign))
	elseif opcode == 0x99 then
		local negative = self:getRegister(0, operandSize) > widthMask(operandSize) / 2
		self:setRegister(2, operandSize, negative and widthMask(operandSize) or 0)
	elseif opcode == 0x9A then
		local offset = self:fetch(operandSize)
		local segment = self:fetch(true)
		self:farTransfer(segment, offset, operandSize, true)
	elseif opcode == 0x9B then
		if self.is386 then
			self:checkFpu(true)
		end
	elseif opcode == 0x9C then
		self:push(self.flags, operandSize)
	elseif opcode == 0x9D then
		self:restoreFlags(self:pop(operandSize), operandSize)
	elseif opcode == 0x9E then
		self.flags = bor(band(self.flags, 0xFFFFFF02), band(self:getRegister(4, false), 0xD5))
	elseif opcode == 0x9F then
		self:setRegister(4, false, self.flags)
	elseif opcode >= 0xA0 and opcode <= 0xA3 then
		local offset = self:fetch(addressSize)
		local segment = self.s[override or DS]
		if opcode < 0xA2 then
			self:setRegister(0, wide, self:read(segment, offset, wide))
		else
			self:write(segment, offset, wide, self:getRegister(0, wide))
		end
	elseif opcode == 0xA8 or opcode == 0xA9 then
		self:alu(4, self:getRegister(0, wide), self:fetch(wide), wide)
	elseif opcode >= 0xA4 and opcode <= 0xAF then
		return self:stringInstruction(opcode, self.s[override or DS], repeatPrefix, startIp, repeatLimit, wide)
	elseif opcode >= 0xB0 and opcode <= 0xBF then
		local word = opcode >= 0xB8 and operandSize
		self:setRegister(band(opcode, 7), word, self:fetch(word))
	elseif opcode == 0xC2 or opcode == 0xC3 or opcode == 0xCA or opcode == 0xCB then
		local discard = not wide and self:fetch(true) or 0
		if opcode >= 0xCA then
			self:farReturn(operandSize, discard)
		else
			self.ip = self:pop(operandSize)
			self:adjustStack(discard)
		end
	elseif opcode == 0xC4 or opcode == 0xC5 then
		local register, operand, segment = self:decodeOperand(override)
		assert(segment ~= nil, "LDS and LES require a memory pointer")
		local value = self:read(segment, operand, operandSize)
		self:loadSegment(
			wide and DS or ES,
			self:read(segment, band(operand + widthBytes(operandSize), self.addressMask), true)
		)
		self:setRegister(register, operandSize, value)
	elseif opcode == 0xC6 or opcode == 0xC7 then
		local register, operand, segment = self:decodeOperand(override)
		assert(register == 0, "Invalid MOV immediate encoding")
		self:writeOperand(operand, segment, wide, self:fetch(wide))
	elseif opcode == 0xCC then
		self:interrupt(3, true)
	elseif opcode == 0xCD then
		self:interrupt(self:fetch8(), true)
	elseif opcode == 0xCE then
		if band(self.flags, OF) ~= 0 then
			self:interrupt(4, true)
		end
	elseif opcode == 0xCF then
		self:iret(operandSize)
	elseif opcode >= 0xD0 and opcode <= 0xD3 then
		local operation, operand, segment = self:decodeOperand(override)
		local count = opcode < 0xD2 and 1 or self:getRegister(1, false)
		if self.is386 then
			count = band(count, 31)
		end
		if count > 0 then
			local result = self:shift(operation, self:readOperand(operand, segment, wide), wide, count)
			self:writeOperand(operand, segment, wide, result)
		end
	elseif opcode == 0xD4 or opcode == 0xD5 then -- AAM / AAD
		local base = self:fetch8()
		local al = self:getRegister(0, false)
		if opcode == 0xD4 and base == 0 then
			self:divideError()
		else
			if opcode == 0xD4 then
				self:setRegister(0, true, math.floor(al / base) * 256 + al % base)
			else
				self:setRegister(0, true, band(self:getRegister(4, false) * base + al, 0xFF))
			end
			self.flags = bor(band(self.flags, bit32.bnot(PF + ZF + SF)), resultFlags(band(self.r[AX], 0xFF), 0x80))
		end
	elseif opcode == 0xD6 then -- SALC
		self:setRegister(0, false, band(self.flags, CF) ~= 0 and 0xFF or 0)
	elseif opcode == 0xD7 then
		local offset = band(self.r[4] + self:getRegister(0, false), self.addressMask)
		self:setRegister(0, false, self:read(self.s[override or DS], offset, false))
	elseif opcode >= 0xD8 and opcode <= 0xDF then
		-- An ESC memory operand still generates a bus read on an 8088.
		if self.is386 then
			self:checkFpu(false)
		end
		local _, operand, segment = self:decodeOperand(override)
		if segment ~= nil then
			self:read(segment, operand, true)
		end
	elseif opcode >= 0xE0 and opcode <= 0xE3 then
		local delta = signed8(self:fetch8())
		local count = self:getRegister(CX - 1, addressSize)
		local jump
		if opcode == 0xE3 then
			jump = count == 0
		else
			count = band(count - 1, self.addressMask)
			self:setRegister(CX - 1, addressSize, count)
			local zero = band(self.flags, ZF) ~= 0
			jump = count ~= 0 and (opcode == 0xE2 or zero == (opcode == 0xE1))
		end
		if jump then
			self.ip = band(self.ip + delta, self.codeMask)
		end
	elseif opcode >= 0xE4 and opcode <= 0xE7 then
		self:portInstruction(opcode, self:fetch8(), wide)
	elseif opcode == 0xE8 or opcode == 0xE9 or opcode == 0xEB then
		local short = opcode == 0xEB
		local delta = short and signed8(self:fetch8()) or self:fetch(operandSize)
		if opcode == 0xE8 then
			self:push(self.ip, operandSize)
		end
		self.ip = band(self.ip + delta, short and self.codeMask or widthMask(operandSize))
	elseif opcode == 0xEA then
		local offset = self:fetch(operandSize)
		self:farTransfer(self:fetch(true), offset, operandSize, false)
	elseif opcode >= 0xEC and opcode <= 0xEF then
		self:portInstruction(opcode, self:getRegister(2, true), wide)
	elseif opcode == 0xF4 then
		if self.is386 then
			self:checkHalt()
		end
		self.halted = true
	elseif opcode == 0xF5 then
		self.flags = bxor(self.flags, CF)
	elseif opcode == 0xF6 or opcode == 0xF7 then
		local operation, operand, segment = self:decodeOperand(override)
		local value = self:readOperand(operand, segment, wide)
		if operation <= 1 then
			self:alu(4, value, self:fetch(wide), wide)
		elseif operation == 2 then
			self:writeOperand(operand, segment, wide, bit32.bnot(value))
		elseif operation == 3 then
			self:writeOperand(operand, segment, wide, self:alu(5, 0, value, wide))
		else
			self:multiplyDivide(operation, value, wide)
		end
	elseif opcode >= 0xF8 and opcode <= 0xFD then
		if self.is386 and (opcode == 0xFA or opcode == 0xFB) then
			self:checkInterruptFlag()
		end
		local flag = opcode < 0xFA and CF or (opcode < 0xFC and IF or DF)
		if wide then
			self.flags = bor(self.flags, flag)
			self.interruptShadow = opcode == 0xFB
		else
			self.flags = band(self.flags, bit32.bnot(flag))
		end
	elseif opcode == 0xFE or opcode == 0xFF then
		local operation, operand, segment = self:decodeOperand(override)
		local value = self:readOperand(operand, segment, wide)
		if operation <= 1 then
			local carry = band(self.flags, CF)
			local result = self:alu(operation == 0 and 0 or 5, value, 1, wide)
			self.flags = bor(band(self.flags, bit32.bnot(CF)), carry)
			self:writeOperand(operand, segment, wide, result)
		elseif wide and operation <= 5 then
			local far = band(operation, 1) ~= 0
			local call = operation < 4
			if far then
				assert(segment ~= nil, "Far CALL/JMP requires a memory pointer")
				local selector = self:read(segment, band(operand + widthBytes(operandSize), self.addressMask), true)
				self:farTransfer(selector, value, operandSize, call)
			else
				if call then
					self:push(self.ip, operandSize)
				end
				self.ip = value
			end
		elseif wide and operation == 6 then
			self:push(not self.is386 and segment == nil and operand == SP - 1 and value - 2 or value, operandSize)
		else
			error("Invalid FE/FF encoding", 0)
		end
	else
		error(
			string.format(
				"Unsupported %s opcode %02X at %04X:%04X",
				self.is386 and "386" or "8088",
				opcode,
				self:selector(CS),
				startIp
			),
			0
		)
	end
end

return Cpu
