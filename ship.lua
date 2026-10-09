-- Ship Pilot: fly a Create Aeronautics ship from a Linked Typewriter.
--
--   W          forward thrusters
--   S          backward (turning propellers both push back)
--   A / D      turn left / right (turning propellers push opposite ways)
--   Space      up
--   Left Shift down
--
-- Usage:  ship         fly
--         ship test    try each relay output and the lift by hand, to fill
--                      in GEARS and MOVES below
--
-- Everything is on the wired modem network: the Linked Typewriter, the
-- thrusters, the Redstone Transmission driving the lift propellers, and the
-- Redstone Relays powering the two Directional Gearshifts.

VERSION = "1.0.0"

-- ======================== SETTINGS ===========================
-- Updates replace this file. Put your own values in ship_settings.lua
-- instead (same lines, e.g.  FORWARD_POWER = 10 ).

-- Which typewriter keys do what (names from CC's keys API).
KEYS = { forward = "w", back = "s", left = "a", right = "d", up = "space", down = "leftShift" }

FORWARD_POWER = 15      -- thruster power while W is held (0-15)
THRUST_RAMP = 30        -- how fast thrusters spool up and down (power per second)

-- Each Directional Gearshift has a straight side (passes rotation on) and a
-- reverse side (reverses it). Power both or neither and it stops. Say which
-- Redstone Relay side is wired to each. Run "ship test" to check.
GEARS = {
  left = {
    straight = { relay = "redstone_relay_0", side = "left" },
    reverse  = { relay = "redstone_relay_0", side = "right" },
  },
  right = {
    straight = { relay = "redstone_relay_1", side = "left" },
    reverse  = { relay = "redstone_relay_1", side = "right" },
  },
}

-- What each gearshift does for each move: "straight", "reverse" or "stop".
-- If the ship turns the wrong way or goes forward instead of back, swap
-- them here.
MOVES = {
  turnLeft  = { left = "reverse",  right = "straight" },
  turnRight = { left = "straight", right = "reverse" },
  back      = { left = "reverse",  right = "reverse" },
}

-- Lift. The Redstone Transmission is switched to incremental mode, which
-- takes 0-256 (16 times finer than a redstone signal).
-- On a Sable ship (CC: Sable) it holds its height when Space and Shift are
-- both released, and learns how much lift that takes.
ALT_HOLD = true
CLIMB_SPEED = 4         -- blocks per second up or down while Space/Shift is held
LIFT_GAIN = 20          -- shift level per block/s of vertical speed error
LIFT_LEARN = 8          -- how fast it learns the hovering shift level
-- Without altitude hold (or off a Sable ship), Space/Shift just raise and
-- lower the shift level at this rate per second.
MANUAL_LIFT_RATE = 64

-- ===================== END OF SETTINGS =======================

if fs.exists("ship_settings.lua") then
  local f, err = loadfile("ship_settings.lua", nil, _ENV)
  if not f then error("ship_settings.lua: " .. err, 0) end
  f()
end

local THRUSTER_TYPES = { thruster = true, creative_thruster = true, solid_fuel_thruster = true, ion_thruster = true }

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function now() return os.epoch("utc") / 1000 end

-- ---------- hardware ----------

local typewriter = peripheral.find("linked_typewriter")
local transmission = peripheral.find("redstone_transmission")
local thrusters = {}
for _, name in ipairs(peripheral.getNames()) do
  if THRUSTER_TYPES[peripheral.getType(name)] then thrusters[#thrusters + 1] = peripheral.wrap(name) end
end

local problems = {}
if not typewriter then problems[#problems + 1] = "No Linked Typewriter on the network." end
if not transmission then problems[#problems + 1] = "No Redstone Transmission on the network." end
if #thrusters == 0 then problems[#problems + 1] = "No thrusters on the network." end
for gear, sides in pairs(GEARS) do
  for which, out in pairs(sides) do
    if peripheral.getType(out.relay) ~= "redstone_relay" then
      problems[#problems + 1] = string.format("GEARS.%s.%s: no Redstone Relay called %s.", gear, which, out.relay)
    end
  end
end

-- Relay outputs, only touched when they change.
local relayState = {}
local function setRelay(out, on)
  local key = out.relay .. ":" .. out.side
  if relayState[key] == on then return end
  relayState[key] = on
  pcall(peripheral.call, out.relay, "setOutput", out.side, on)
end

local gearMode = { left = "stop", right = "stop" }
local function setGear(gear, mode)
  gearMode[gear] = mode
  local g = GEARS[gear]
  if not g then return end
  setRelay(g.straight, mode == "straight")
  setRelay(g.reverse, mode == "reverse")
end

local thrust = 0
local function setThrusters(power)
  local p = math.floor(clamp(power, 0, 15) + 0.5)
  for _, t in ipairs(thrusters) do pcall(t.setPower, p) end
end

local shift = 0
local sentShift = nil
local function setShift(v)
  shift = clamp(v, 0, 256)
  local s = math.floor(shift + 0.5)
  if s ~= sentShift then
    sentShift = s
    pcall(transmission.setShiftLevel, s)
  end
end

local function allStop()
  setThrusters(0)
  setGear("left", "stop")
  setGear("right", "stop")
end

-- ---------- keys ----------

local held = {}
local function readKeys()
  held = {}
  local ok, codes = pcall(typewriter.getPressedKeyCodes)
  if ok and type(codes) == "table" then
    for _, c in ipairs(codes) do held[c] = true end
  end
end

local function down(action)
  local code = keys[KEYS[action]]
  return code ~= nil and held[code] == true
end

-- ---------- height (CC: Sable) ----------

local onSable = sublevel ~= nil and sublevel.isInPlotGrid()
local alt, vy, lastAltT = nil, 0, nil
local function readHeight()
  if not onSable then return end
  local ok, pose = pcall(sublevel.getLogicalPose)
  if not ok or not pose then return end
  local y, t = pose.position.y, now()
  if alt and lastAltT and t > lastAltT then
    vy = vy * 0.5 + (y - alt) / (t - lastAltT) * 0.5
  end
  alt, lastAltT = y, t
end

-- ---------- test mode ----------

local function testMode()
  local outs = {}
  for _, gear in ipairs({ "left", "right" }) do
    for _, which in ipairs({ "straight", "reverse" }) do
      local o = GEARS[gear] and GEARS[gear][which]
      if o then outs[#outs + 1] = { label = gear .. " gearshift, " .. which .. " side", out = o, on = false } end
    end
  end
  local thrustOn = false
  pcall(transmission.setTransmissionMode, "incremental")
  local ok, cur = pcall(transmission.getShiftLevel)
  setShift(ok and cur or 0)
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print("Ship Pilot v" .. VERSION .. " - TEST MODE (computer keyboard)")
    print("")
    for i, o in ipairs(outs) do
      print(string.format("%d  %-34s %s", i, o.label .. " (" .. o.out.relay .. " " .. o.out.side .. ")", o.on and "ON" or "off"))
    end
    print(string.format("T  forward thrusters (%d found)       %s", #thrusters, thrustOn and "ON" or "off"))
    print(string.format("+/-  lift shift level                %d / 256", math.floor(shift + 0.5)))
    print("")
    print("Q  quit (relays and thrusters off)")
    local _, ch = os.pullEvent("char")
    local n = tonumber(ch)
    if n and outs[n] then
      outs[n].on = not outs[n].on
      setRelay(outs[n].out, outs[n].on)
    elseif ch == "t" then
      thrustOn = not thrustOn
      setThrusters(thrustOn and FORWARD_POWER or 0)
    elseif ch == "+" or ch == "=" then
      setShift(shift + 16)
    elseif ch == "-" then
      setShift(shift - 16)
    elseif ch == "q" then
      for _, o in ipairs(outs) do setRelay(o.out, false) end
      setThrusters(0)
      return
    end
  end
end

-- ---------- flying ----------

local function fly()
  pcall(transmission.setTransmissionMode, "incremental")
  local ok, cur = pcall(transmission.getShiftLevel)
  setShift(ok and type(cur) == "number" and cur or 0)
  local hover = shift
  local holding = ALT_HOLD and onSable
  local holdAlt = nil   -- height to stay at while Space/Shift are released
  local last = now()
  local status = ""

  while true do
    local t = now()
    local dt = math.min(t - last, 0.5)
    last = t
    readKeys()
    readHeight()

    -- forward
    local want = down("forward") and FORWARD_POWER or 0
    local step = THRUST_RAMP * dt
    thrust = thrust + clamp(want - thrust, -step, step)
    setThrusters(thrust)

    -- turning wins over backward when both are held
    local move = nil
    if down("left") and not down("right") then move = MOVES.turnLeft
    elseif down("right") and not down("left") then move = MOVES.turnRight
    elseif down("back") then move = MOVES.back end
    setGear("left", move and move.left or "stop")
    setGear("right", move and move.right or "stop")

    -- lift
    local updown = (down("up") and 1 or 0) - (down("down") and 1 or 0)
    if holding and alt then
      local wantVy = updown * CLIMB_SPEED
      if updown ~= 0 then
        holdAlt = nil
      else
        holdAlt = holdAlt or alt
        wantVy = clamp(0.5 * (holdAlt - alt), -CLIMB_SPEED, CLIMB_SPEED)
      end
      local err = wantVy - vy
      hover = clamp(hover + LIFT_LEARN * err * dt, 0, 256)
      setShift(hover + LIFT_GAIN * err)
      status = updown == 0 and string.format("holding height %.1f", holdAlt) or (updown > 0 and "climbing" or "descending")
    else
      setShift(shift + updown * MANUAL_LIFT_RATE * dt)
      status = updown == 0 and "lift steady" or (updown > 0 and "more lift" or "less lift")
    end

    -- screen
    term.clear()
    term.setCursorPos(1, 1)
    print("Ship Pilot v" .. VERSION)
    print("")
    local names = {}
    for action, name in pairs(KEYS) do if down(action) then names[#names + 1] = name end end
    table.sort(names)
    print("Keys:      " .. (#names > 0 and table.concat(names, " ") or "-"))
    print(string.format("Thrust:    %d / 15  (%d thrusters)", math.floor(thrust + 0.5), #thrusters))
    print(string.format("Gears:     left %s, right %s", gearMode.left, gearMode.right))
    print(string.format("Lift:      %d / 256  %s", math.floor(shift + 0.5), status))
    if alt then print(string.format("Height:    %.1f  (%+.1f b/s)", alt, vy)) end
    print("")
    print("Ctrl+T to stop. Lift stays where it is.")
    sleep(0.05)
  end
end

-- ---------- main ----------

local args = { ... }
if #problems > 0 then
  for _, p in ipairs(problems) do print(p) end
  print("")
  print("Right-click each part's wired modem to connect it; the chat shows its name.")
  return
end

local ok, err = pcall(args[1] == "test" and testMode or fly)
-- Thrusters and turning off; lift left alone so the ship doesn't drop.
allStop()
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then print("Stopped: " .. tostring(err)) end
print("Thrusters and turning are off. Lift is still at " .. math.floor(shift + 0.5) .. " / 256.")
