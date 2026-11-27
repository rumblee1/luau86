local SerialMouse = require("../src/SerialMouse")

local function poweredMouse(interactive)
	local interrupts = 0
	local mouse = SerialMouse.new(function()
		interrupts += 1
	end)
	if interactive then
		mouse:useInteractiveTiming()
	end
	mouse:write(0x3F9, 1, 0)
	mouse:write(0x3FC, 0x0B, 0)
	assert(mouse.deliverAt == 3 * 8949)
	mouse:advance(mouse.deliverAt)
	assert(mouse:read(0x3F8, 3 * 8949) == 0x4D and interrupts == 1)
	return mouse, function()
		return interrupts
	end
end

local function read(mouse)
	local now = mouse.deliverAt
	mouse:advance(now)
	assert(bit32.band(mouse:read(0x3FD, now), 1) ~= 0)
	return mouse:read(0x3F8, now)
end

local mouse = poweredMouse(false)
local now = 50000
mouse:advance(now)
mouse:move(1, 0, 0, now)
assert(mouse.deliverAt == now + 8949)
assert(read(mouse) == 0x40 and read(mouse) == 1 and read(mouse) == 0)
assert(mouse.deliverAt == now + 4 * 8949)

local count
mouse, count = poweredMouse(true)
mouse:advance(now)
mouse:move(250, -140, 0, now, 123)
mouse:move(0, 0, 0x20, now)
mouse:move(0, 0, 0, now)
assert(mouse.deliverAt == now + 2237)
assert(read(mouse) == 0x49 and read(mouse) == 63 and read(mouse) == 0)
assert(mouse.lastMotionReadAt == 123 and mouse.motionReports == 1)
assert(read(mouse) == 0x4D and read(mouse) == 59 and read(mouse) == 52)
assert(mouse.motionReports == 2 and mouse.deliverAt == now + 7 * 2237)
assert(read(mouse) == 0x60 and read(mouse) == 0 and read(mouse) == 0)
assert(read(mouse) == 0x40 and read(mouse) == 0 and read(mouse) == 0)
assert(count() == 13, "Every serial byte received a separate interrupt")

local start = now + 30 * 2237
mouse:move(1, 2, 0, start)
mouse:advance(mouse.deliverAt)
local due = mouse.deliverAt
mouse:advance(due)
assert(mouse:read(0x3F8, due + 5) == 0x40)
assert(mouse.deliverAt == due + 6 and read(mouse) == 1 and read(mouse) == 2)
print(
	"Interactive COM1 shortened report time from about 22.5 ms to 5.6 ms, preserved motion and button order, and kept UART backpressure"
)
