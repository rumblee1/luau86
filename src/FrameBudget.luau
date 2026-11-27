local MIN_BUDGET = 0.002
local DEFAULT_BUDGET = 0.004
local MAX_BUDGET = 0.012
local MAX_INDEXED_BUDGET = 0.016
local MAX_FRAME_SAMPLE = 1 / 30
local BUDGET_RECOVERY = 0.001

local FrameBudget = {}
FrameBudget.__index = FrameBudget

function FrameBudget.new(clockRate)
	return setmetatable({
		clockRate = clockRate,
		budget = DEFAULT_BUDGET,
		frameTime = 1 / 60,
		deviceTime = 0,
		credit = 0,
		saturated = false,
	}, FrameBudget)
end

function FrameBudget:beginFrame(elapsed, adaptive, indexed)
	self.credit = math.min(self.credit + elapsed * self.clockRate, self.clockRate / 10)
	-- Allow a similar share of each frame at different frame rates.
	-- Ignore occasional stalls when estimating the available time.
	if elapsed <= 0.050 then
		self.frameTime += (math.min(elapsed, MAX_FRAME_SAMPLE) - self.frameTime) * 0.15
	end
	if adaptive then
		-- Indexed games spend most of their time drawing inside the guest.
		local share = if indexed then 2 / 3 else 1 / 2
		local maximum = if indexed then MAX_INDEXED_BUDGET else MAX_BUDGET
		local total = math.clamp(self.frameTime * share, DEFAULT_BUDGET, maximum)
		local limit = math.max(MIN_BUDGET, total - self.deviceTime)
		-- Restore CPU headroom promptly when Windows starts drawing or a
		-- program begins loading after an idle stretch.
		local growth = if self.saturated then BUDGET_RECOVERY else 0
		self.budget = math.min(limit, self.budget + growth)
	else
		self.budget = DEFAULT_BUDGET
	end
	return math.floor(self.credit), self.budget
end

function FrameBudget:endFrame(clocks, cpuSeconds, deviceSeconds)
	self.credit -= clocks
	self.saturated = self.credit > self.clockRate * 0.001 and cpuSeconds >= self.budget * 0.9
	-- Reserve time for recent display and audio work. Recover gradually
	-- after a repaint so a burst of video updates leaves the client responsive.
	self.deviceTime = math.max(deviceSeconds, self.deviceTime * 0.75)
end

return FrameBudget
