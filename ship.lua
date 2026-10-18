-- Ship Pilot: fly a Create Aeronautics ship from a Linked Typewriter.
--
-- Starts in a menu on the computer:
--   F  fly (keys on the typewriter, default W A S D, Space, Left Shift,
--      Up/Down arrows for the throttle)
--   T  typewriter test: shows the last key pressed
--   K  keybinds: change which typewriter key does what
--   G  gearshift setup: switch relay sides and save what turns/reverses
--   H  hover calibration: find the lift level that hovers
--   U  tuning: change flight settings with + and -
--   P  thruster setup: mark each thruster as lift, forward, backward,
--      turn left or turn right
--   M  manual test: switch relay sides, thrusters and lift by hand
-- "ship fly" goes straight to flying.
--
-- Hardware, all on the wired modem network: the Linked Typewriter,
-- thrusters (each one marked lift or forward in Thruster setup), optionally
-- a Redstone Transmission driving lift propellers, and one Redstone Relay
-- whose sides (through Redstone Links) power the two Directional
-- Gearshifts on the turning propellers.
--
-- The ship hovers on its own: whenever no up/down key is held (in the
-- menus too) it holds its height. Setup from the menus is saved in
-- ship.cfg.
--
-- Touch: click any key letter or its label on an advanced computer, or tap
-- it on an Advanced Monitor (the screens are mirrored onto one if it's
-- connected and big enough).
--
-- Everything that happens is written to ship.log (the previous run is kept
-- as ship.log.old). To share it:  pastebin put ship.log

VERSION = "4.9.0"

-- ======================== SETTINGS ===========================
-- Change these from the Tuning menu (U) on the computer; what you set
-- there is saved in ship.cfg and overrides the values below.

START_THROTTLE = 5      -- throttle each time Fly opens (0-15)
FORWARD_POWER = 15      -- throttle: thruster power while forward is held (0-15);
                        -- the faster/slower keys change it while flying
BACK_MOMENTUM = 1.5     -- S: extra back power per block/s still moving forward (never below the throttle)
BACK_POWER = 15         -- most power smart braking and the autopilot use backward (S always uses the throttle)
TURN_POWER = 5          -- turning thrusters' power (0-15); also set on the Fly screen
THRUST_RAMP = 30        -- how fast thrusters spool up and down (power per second)
ALT_HOLD = true         -- hold height on a Sable ship (needs CC: Sable)
CLIMB_SPEED = 8         -- blocks per second up or down while the key is held
DOWN_POWER = 15         -- most power the down thrusters use (0-15)
DOWN_GAIN = 3           -- holding height: down power per block/s too fast upward (lift already at 0)
PULSE_LOCK = 1          -- up/down do nothing for this many seconds after a pulse (it holds height)
PULSE_TICKS = 4         -- Pulse: game ticks the signal drops for (set in Gearshifts with +/-)
LIFT_GAIN = 20          -- lift change per block/s of vertical speed error
LIFT_LEARN = 8          -- how fast it fine-tunes the hover level
-- Without altitude hold: how far up/down keys move the lift from the hover level.
MANUAL_LIFT_STEP = 40

-- Smart mode and autopilot (need CC: Sable; run Smart setup once first).
NAV_SPEED = 10          -- autopilot top speed (blocks per second)
HOLD_KP = 0.3           -- B (hold in place): push back per block off the spot
HOLD_KD = 1.2           -- B: push against each block/s of drift
HOLD_KI = 0.08          -- B: slowly builds up a push against steady drift (wind, a tilted thruster)

-- Fuel (lava in the fluid tanks and the thrusters).
LOW_FUEL_SECONDS = 30   -- warn when this much flying time is left
LOW_FUEL_LAND = 15      -- land by itself at this much time left (0 = never)
FUEL_ALARM_PERCENT = 70 -- a connected speaker sounds an alarm below this much lava (0 = off)
NAV_ARRIVE = 2          -- autopilot: this close to the target counts as there
TURN_RATE = 0.6         -- fastest the computer turns the ship (radians per second)
SMART_TURN_RATE = 0.45  -- smart mode: how fast A/D turn the ship (radians per second, ~26 deg/s)

-- Website control: https://levisnakes.github.io/cc-ship-pilot/
-- The menu shows a code to type into the website. Messages go through the
-- free ntfy.sh relay: about 250 a day per IP address, shared by every
-- computer on the Minecraft server (the GPS missile too).
REMOTE = true
TELEMETRY_SECONDS = 5     -- status update interval while moving
REMOTE_DAILY_LIMIT = 150  -- stop sending updates after this many a day

-- ===================== END OF SETTINGS =======================

if fs.exists("ship_settings.lua") then
  local f, err = loadfile("ship_settings.lua", nil, _ENV)
  if not f then error("ship_settings.lua: " .. err, 0) end
  f()
end

local CONFIG_FILE = "ship.cfg"
local THRUSTER_TYPES = { thruster = true, creative_thruster = true, solid_fuel_thruster = true, ion_thruster = true }
local RELAY_SIDES = { "front", "back", "left", "right", "top", "bottom" }
local ACTIONS = {
  { id = "forward", label = "Forward" },
  { id = "back",    label = "Backward" },
  { id = "left",    label = "Turn left" },
  { id = "right",   label = "Turn right" },
  { id = "up",      label = "Up" },
  { id = "down",    label = "Down" },
  { id = "faster",  label = "Faster" },
  { id = "slower",  label = "Slower" },
  { id = "boost",   label = "Boost" },
  { id = "pulse",   label = "Pulse" },
  { id = "sleft",   label = "Strafe left" },
  { id = "sright",  label = "Strafe right" },
  { id = "brake",   label = "Stop & hold" },
}
local DEFAULT_KEYS = { forward = "w", back = "s", left = "a", right = "d", up = "space", down = "leftShift",
  faster = "up", slower = "down", boost = "leftCtrl", pulse = "r", sleft = "q", sright = "e", brake = "b" }
-- cc-warship: a typewriter key arms and safes the auto cannons.
if WARSHIP then
  ACTIONS[#ACTIONS + 1] = { id = "arm", label = "Arm/safe guns" }
  DEFAULT_KEYS.arm = "f"
end

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function now() return os.epoch("utc") / 1000 end

-- ---------- hardware ----------

-- Every peripheral once. With two modems on the same network CC lists each
-- name twice, and a thruster listed twice would get two different powers.
local function peripheralNames()
  local seen, list = {}, {}
  for _, name in ipairs(peripheral.getNames()) do
    if not seen[name] then seen[name] = true list[#list + 1] = name end
  end
  return list
end

local typewriter = peripheral.find("linked_typewriter")
local transmission = peripheral.find("redstone_transmission")
local thrusters, relays = {}, {}   -- thrusters: { name = , p = }
for _, name in ipairs(peripheralNames()) do
  local t = peripheral.getType(name)
  if THRUSTER_TYPES[t] then thrusters[#thrusters + 1] = { name = name, p = peripheral.wrap(name) } end
  if t == "redstone_relay" then relays[#relays + 1] = name end
end
table.sort(relays)
local function natural(name)
  local base, n = name:match("^(.-)(%d+)$")
  return base or name, tonumber(n) or -1
end
table.sort(thrusters, function(a, b)
  local ab, an = natural(a.name)
  local bb, bn = natural(b.name)
  if ab ~= bb then return ab < bb end
  return an < bn
end)

-- Velocity Sensors (Create Simulated): speed along the way they face.
local velSensors = {}
for _, name in ipairs(peripheralNames()) do
  if peripheral.getType(name) == "velocity_sensor" then
    local p = peripheral.wrap(name)
    local ok, axis = pcall(p.getAxis)
    velSensors[#velSensors + 1] = { name = name, p = p, axis = ok and axis or "?" }
  end
end
local lastVel = {}
local function readVelocity()
  for i, v in ipairs(velSensors) do
    local ok, val = pcall(v.p.getVelocity)
    lastVel[i] = ok and val or nil
  end
end
local function velText()
  local parts = {}
  for i, v in ipairs(velSensors) do
    parts[#parts + 1] = string.format("%s=%s", v.axis, lastVel[i] and string.format("%.2f", lastVel[i]) or "?")
  end
  return #parts > 0 and table.concat(parts, " ") or "-"
end

-- ---------- log ----------
-- The log rotates: at LOG_LIMIT it becomes ship.log.old and a new one
-- starts, so the two together stay under 2 x LOG_LIMIT. Logging can never
-- stop the program: if the disk is low or a write fails, it just stops.
local LOG_FILE, LOG_LIMIT, LOG_MIN_FREE = "ship.log", 60000, 150000
local logFile, logBytes = nil, 0
local logStart = now()
local function log(fmt, ...)
  if not logFile then return end
  local fok, text = pcall(string.format, fmt, ...)
  if not fok then text = tostring(fmt) end
  local ok = pcall(function()
    local line = string.format("%8.2f ", now() - logStart) .. text
    if logBytes + #line + 1 > LOG_LIMIT then
      logFile.close()
      if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
      fs.move(LOG_FILE, LOG_FILE .. ".old")
      logFile = fs.open(LOG_FILE, "w")
      logBytes = 0
    end
    if fs.getFreeSpace("/") < LOG_MIN_FREE then
      if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
      if fs.getFreeSpace("/") < LOG_MIN_FREE then
        logFile.writeLine("disk nearly full - logging stopped")
        logFile.close()
        logFile = nil
        return
      end
    end
    logFile.writeLine(line)
    logFile.flush()
    logBytes = logBytes + #line + 1
  end)
  if not ok then
    pcall(function() logFile.close() end)
    logFile = nil
  end
end

-- ---------- saved setup ----------

local cfg

local function defaultConfig()
  local r = relays[1] or "redstone_relay_0"
  return {
    keys = {},
    -- Relay sides switched on for each move. One relay, a Redstone Link
    -- on four of its sides; Gearshift setup (G) records the real ones.
    moves = {
      left  = { { relay = r, side = "back" },  { relay = r, side = "left" } },
      right = { { relay = r, side = "front" }, { relay = r, side = "right" } },
      back  = { { relay = r, side = "back" },  { relay = r, side = "right" } },
    },
    hover = nil,
    tune = {},
    roles = {},   -- thruster name -> lift, forward, back, left, right or off
  }
end

local function saveConfig()
  -- Never crash over a full disk: keep flying, try again next save.
  local ok, err = pcall(function()
    local h = fs.open(CONFIG_FILE, "w")
    h.write(textutils.serialize(cfg))
    h.close()
  end)
  if not ok then log("saving ship.cfg FAILED: %s", tostring(err)) end
end

local function loadConfig()
  cfg = defaultConfig()
  if fs.exists(CONFIG_FILE) then
    local h = fs.open(CONFIG_FILE, "r")
    local saved = textutils.unserialize(h.readAll())
    h.close()
    if type(saved) == "table" then
      for k, v in pairs(saved) do cfg[k] = v end
    end
  end
  for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = cfg.keys[id] or name end
  -- v2.0 saved moves as numbers into an outputs list.
  if cfg.outputs then
    for id, list in pairs(cfg.moves) do
      if type(list[1]) == "number" then
        local conv = {}
        for _, i in ipairs(list) do
          local o = cfg.outputs[i]
          if o then conv[#conv + 1] = { relay = o.relay, side = o.side } end
        end
        cfg.moves[id] = conv
      end
    end
    cfg.outputs = nil
  end
  cfg.tune = cfg.tune or {}
  cfg.roles = cfg.roles or {}
  -- v3.6: turning thrusters were far too strong at 15; start everyone at 5 once.
  if not cfg.turnPower36 then
    cfg.turnPower36 = true
    cfg.tune.TURN_POWER = 5
  end
  -- v3.9: climbing was too slow at 4 blocks/s; move the old default to 8 once.
  if not cfg.climb39 then
    cfg.climb39 = true
    if cfg.tune.CLIMB_SPEED == nil or cfg.tune.CLIMB_SPEED == 4 then cfg.tune.CLIMB_SPEED = 8 end
  end
  -- v4.5.1: the pulse drives a toggle latch, which only wants a short
  -- on-pulse; make that the default once (O in Gearshifts switches back).
  if not cfg.blip451 then
    cfg.blip451 = true
    cfg.pulseBlip = true
  end
  -- v4.8: Q/E strafe and F arms the guns; the pulse moves off Q to R.
  -- Once, swapping with whatever already had those keys.
  if not cfg.keysQE48 then
    cfg.keysQE48 = true
    local function bind(id, name)
      for other, k in pairs(cfg.keys) do
        if k == name and other ~= id then cfg.keys[other] = cfg.keys[id] end
      end
      cfg.keys[id] = name
    end
    if cfg.keys.pulse == "q" then bind("pulse", "r") end
    bind("sleft", "q")
    bind("sright", "e")
    if WARSHIP then bind("arm", "f") end
  end
  for name, v in pairs(cfg.tune) do _ENV[name] = v end
end

-- ---------- outputs ----------

local outState = {}
local relayError = nil
local function setOutput(o, on)
  local key = o.relay .. ":" .. o.side
  if outState[key] == on then return end
  local ok, err = pcall(peripheral.call, o.relay, "setOutput", o.side, on)
  if ok then
    outState[key] = on
    log("relay %s %s -> %s", o.relay, o.side, on and "ON" or "off")
  else
    relayError = string.format("%s %s: %s", o.relay, o.side, tostring(err))
    log("relay %s %s -> %s FAILED: %s", o.relay, o.side, on and "ON" or "off", tostring(err))
  end
end

-- The Pulse output: a relay side that's always on, except for a tick
-- each time the pulse key is pressed on the typewriter.
local function isPulse(o)
  return cfg.pulse ~= nil and o.relay == cfg.pulse.relay and o.side == cfg.pulse.side
end
-- Resting state: "drop" pulses sit on and drop for a moment; "blip"
-- pulses sit off and come on for a moment (for a toggle latch: a reboot
-- or reset then can't flip it).
local function pulseOn()
  if cfg.pulse then setOutput(cfg.pulse, not cfg.pulseBlip) end
end

local function allRelaysOff()
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do
      local o = { relay = r, side = side }
      if not isPulse(o) then setOutput(o, false) end
    end
  end
end

local pulsing, lastPulse, pulseMissingAt = false, nil, nil
local upDownLockUntil = nil   -- no up/down until then (after a pulse)
local function pulse()
  if not cfg.pulse or pulsing then return end
  pulsing = true
  upDownLockUntil = math.huge   -- no up/down during the pulse...
  local rest = not cfg.pulseBlip
  outState[cfg.pulse.relay .. ":" .. cfg.pulse.side] = nil
  setOutput(cfg.pulse, not rest)
  sleep(0.05 * math.max(1, cfg.pulseTicks or PULSE_TICKS))
  setOutput(cfg.pulse, rest)
  pulsing, lastPulse = false, now()
  upDownLockUntil = now() + PULSE_LOCK   -- ...or for PULSE_LOCK seconds after it
  log("Pulse sent (%s, %d ticks)", cfg.pulseBlip and "blip" or "drop", cfg.pulseTicks or PULSE_TICKS)
end

local currentMove = nil
local function applyMove(move)
  if move ~= currentMove then log("move: %s", move or "none") end
  currentMove = move
  local on = {}
  for _, o in ipairs(move and cfg.moves[move] or {}) do on[o.relay .. ":" .. o.side] = true end
  -- Every side used by any move: on if it's in this one, off otherwise.
  for _, list in pairs(cfg.moves) do
    for _, o in ipairs(list) do setOutput(o, on[o.relay .. ":" .. o.side] == true) end
  end
end

local function describe(list)
  if not list or #list == 0 then return "nothing" end
  local parts = {}
  for _, o in ipairs(list) do parts[#parts + 1] = (#relays > 1 and (o.relay .. " ") or "") .. o.side end
  return table.concat(parts, "+")
end

-- Each thruster is marked lift, forward or off in Thruster setup (P).
-- Unmarked ones push forward when there's a transmission for lift.
-- Movement thruster groups, fired by their keys while flying.
local GROUPS = { "forward", "back", "left", "right", "sleft", "sright" }
local ROLE_LABEL = { lift = "lift", down = "down", forward = "forward", back = "backward", left = "turn left",
  sleft = "strafe left", sright = "strafe right",
  right = "turn right", off = "off", unset = "NOT SET" }
local MOVE = { forward = true, back = true, left = true, right = true, sleft = true, sright = true }
local group = { forward = {}, back = {}, left = {}, right = {}, sleft = {}, sright = {} }
local forwardT, liftT, moveT = group.forward, {}, {}
local downT = {}

-- A thruster is "lift", "off", or has one or more movement jobs (e.g.
-- turn left AND backward), saved as a list.
local function rawRole(t)
  return cfg.roles[t.name] or (transmission and "forward" or nil)
end
local function rolesOf(t)   -- set of movement jobs
  local r, set = rawRole(t), {}
  if type(r) == "table" then
    for _, g in ipairs(r) do set[g] = true end
  elseif MOVE[r] then
    set[r] = true
  end
  return set
end
local function roleOf(t)    -- "lift", "down", "off", "move" or "unset"
  local r = rawRole(t)
  if type(r) == "table" then return #r > 0 and "move" or "unset" end
  if MOVE[r] then return "move" end
  return r or "unset"
end
local function roleText(t)
  local r = roleOf(t)
  if r ~= "move" then return ROLE_LABEL[r] or r end
  local parts, set = {}, rolesOf(t)
  for _, g in ipairs(GROUPS) do if set[g] then parts[#parts + 1] = ROLE_LABEL[g] end end
  return table.concat(parts, "+")
end
local function sortThrusters()
  group = { forward = {}, back = {}, left = {}, right = {}, sleft = {}, sright = {} }
  liftT, moveT, downT = {}, {}, {}
  for _, t in ipairs(thrusters) do
    local r = roleOf(t)
    if r == "lift" then
      liftT[#liftT + 1] = t
    elseif r == "down" then
      downT[#downT + 1] = t
    elseif r == "move" then
      t.jobs = rolesOf(t)
      moveT[#moveT + 1] = t
      for g in pairs(t.jobs) do group[g][#group[g] + 1] = t end
    end
  end
  forwardT = group.forward
end

-- Peripheral calls each take a game tick, so send them all at once.
local function callAll(calls)
  if #calls == 1 then calls[1]() elseif #calls > 1 then parallel.waitForAll(table.unpack(calls)) end
end

local function powerCall(t, p)
  return function()
    local ok, err = pcall(t.p.setPower, p)
    if not ok then log("thruster %s setPower(%d) FAILED: %s", t.name, p, tostring(err)) end
  end
end

local thrust = 0                 -- forward power right now (spooling)
local groupPower = { forward = 0, back = 0, left = 0, right = 0, sleft = 0, sright = 0 }
local groupSent = {}
local sentThrust = nil

local thrusterSent = {}

-- Sets every group's power in one go (each call takes a tick). A thruster
-- with several jobs fires at the strongest of them.
local function setGroups(want)
  for _, g in ipairs(GROUPS) do
    local p = math.floor(clamp(want[g] or 0, 0, 15) + 0.5)
    groupPower[g] = want[g] or 0
    if p ~= groupSent[g] then
      if p == 0 or groupSent[g] == 0 or groupSent[g] == nil then log("%s thrusters -> %d", g, p) end
      groupSent[g] = p
    end
  end
  local calls = {}
  for _, t in ipairs(moveT) do
    local p = 0
    for g in pairs(t.jobs) do p = math.max(p, groupSent[g] or 0) end
    if thrusterSent[t.name] ~= p then
      thrusterSent[t.name] = p
      calls[#calls + 1] = powerCall(t, p)
    end
  end
  callAll(calls)
end

local function setThrusters(power)
  thrust = power
  setGroups({ forward = power, back = groupPower.back, left = groupPower.left, right = groupPower.right,
    sleft = groupPower.sleft, sright = groupPower.sright })
end

local function allThrustOff()
  thrust = 0
  setGroups({ forward = 0, back = 0, left = 0, right = 0 })
end

-- Lift level 0-256. With lift thrusters it's shared out between them:
-- 8 thrusters x 15 power steps = 120 steps instead of 15 if they all
-- moved together.
local shift = 0
local sentShift = nil
local liftSent = {}
local function liftAvailable() return #liftT > 0 or transmission ~= nil end
local function setShift(v)
  shift = clamp(v, 0, 256)
  if #liftT > 0 then
    local n = #liftT
    local units = math.floor(shift / 256 * n * 15 + 0.5)
    local base, extra = math.floor(units / n), units % n
    -- Spread the thrusters getting one step more evenly through the list,
    -- so they aren't all on one side of the ship.
    local more = {}
    for j = 0, extra - 1 do more[math.floor((j + 0.5) * n / extra) + 1] = true end
    local calls = {}
    for i, t in ipairs(liftT) do
      local p = base + (more[i] and 1 or 0)
      if liftSent[t.name] ~= p then
        liftSent[t.name] = p
        calls[#calls + 1] = powerCall(t, p)
      end
    end
    callAll(calls)
  elseif transmission then
    local s = math.floor(shift + 0.5)
    if s ~= sentShift then
      sentShift = s
      local ok, err = pcall(transmission.setShiftLevel, s)
      if not ok then log("transmission setShiftLevel(%d) FAILED: %s", s, tostring(err)) end
    end
  end
end

-- Down thrusters: push the ship down, all at the same power.
local downPower = 0
local downSent = {}
local function setDown(p)
  p = math.floor(clamp(p, 0, 15) + 0.5)
  if p ~= downPower then
    if p == 0 or downPower == 0 then log("down thrusters -> %d", p) end
    downPower = p
  end
  local calls = {}
  for _, t in ipairs(downT) do
    if downSent[t.name] ~= p then
      downSent[t.name] = p
      calls[#calls + 1] = powerCall(t, p)
    end
  end
  callAll(calls)
end

-- ---------- typewriter keys ----------

local twHeld = {}     -- keys held on the typewriter right now
local twSeen = {}     -- code -> when the typewriter last had it held
local lastHeldText, twError = nil, nil
local function pollTypewriter()
  local held = {}
  if typewriter then
    local ok, codes = pcall(typewriter.getPressedKeyCodes)
    if ok and type(codes) == "table" then
      local t = now()
      for _, c in ipairs(codes) do held[c], twSeen[c] = true, t end
    elseif not ok and tostring(codes) ~= twError then
      twError = tostring(codes)
      log("typewriter getPressedKeyCodes FAILED: %s", twError)
    end
  end
  twHeld = held
  local names = {}
  for c in pairs(held) do names[#names + 1] = (keys.getName(c) or "?") .. "(" .. c .. ")" end
  table.sort(names)
  local text = #names > 0 and table.concat(names, " ") or "-"
  if text ~= lastHeldText then
    lastHeldText = text
    log("typewriter keys: %s", text)
  end
end

-- Whether a key event came from the typewriter (the computer's own
-- keyboard sends the same events).
local function fromTypewriter(code)
  pollTypewriter()
  return twHeld[code] or (twSeen[code] and now() - twSeen[code] < 0.5)
end

local function keyName(code)
  return (code and keys.getName(code)) or ("code " .. tostring(code))
end

local function down(action)
  local code = keys[cfg.keys[action]]
  return code ~= nil and twHeld[code] == true
end

-- ---------- height and lift ----------

local onSable = sublevel ~= nil and sublevel.isInPlotGrid()
local alt, vy, lastAltT = nil, 0, nil
local posX, posZ = nil, nil
local vx, vz = 0, 0
local yaw, yawRate = nil, 0   -- heading of the ship's +X axis (radians) and how fast it turns

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local function wrapAngle(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a < -math.pi do a = a + 2 * math.pi end
  return a
end
-- Rotates vector v by quaternion q.
local function qrot(q, v)
  local tx = 2 * (q.y * v.z - q.z * v.y)
  local ty = 2 * (q.z * v.x - q.x * v.z)
  local tz = 2 * (q.x * v.y - q.y * v.x)
  return { x = v.x + q.w * tx + (q.y * tz - q.z * ty),
           y = v.y + q.w * ty + (q.z * tx - q.x * tz),
           z = v.z + q.w * tz + (q.x * ty - q.y * tx) }
end

local function readHeight()
  if not onSable then return end
  local ok, pose = pcall(sublevel.getLogicalPose)
  if not ok or not pose then return end
  local y, t = pose.position.y, now()
  local px, pz = pose.position.x, pose.position.z
  -- CC: Sable hands back a quaternion object (v = x/y/z, a = w).
  local o, newYaw = pose.orientation, nil
  if type(o) == "table" then
    local q = o.v and { x = o.v.x, y = o.v.y, z = o.v.z, w = o.a } or { x = o.x, y = o.y, z = o.z, w = o.w }
    if q.w then
      local f = qrot(q, { x = 1, y = 0, z = 0 })
      newYaw = atan2(f.z, f.x)
    end
  end
  if alt and lastAltT and t > lastAltT then
    local dt = t - lastAltT
    vy = vy * 0.5 + (y - alt) / dt * 0.5
    vx = vx * 0.5 + (px - posX) / dt * 0.5
    vz = vz * 0.5 + (pz - posZ) / dt * 0.5
    if newYaw and yaw then yawRate = yawRate * 0.5 + wrapAngle(newYaw - yaw) / dt * 0.5 end
  end
  alt, lastAltT, posX, posZ = y, t, px, pz
  if newYaw then yaw = newYaw end
end

-- mode "off": the lift is left alone (parked, or set by hand in a menu).
-- mode "fly": hover, or climb/sink while up/down is held.
local lift = { mode = "off", updown = 0, hover = nil, holdAlt = nil,
  steadySince = nil, landedSince = nil, status = "parked" }

local function holdingHeight() return ALT_HOLD and onSable and alt ~= nil end

local function liftStep(dt)
  if not liftAvailable() then return end
  -- Read once: setShift yields for a tick, and the screen can change
  -- lift.updown in the meantime.
  local ud = lift.updown
  local locked = upDownLockUntil ~= nil and now() < upDownLockUntil
  if locked then ud = 0 end
  if lift.mode == "off" then
    if ud <= 0 then
      if downPower > 0 then setDown(0) end
      return
    end
    -- Take off: start from the saved hover level.
    lift.mode = "fly"
    lift.hover = math.max(shift, cfg.hover or 0)
    lift.holdAlt = nil
    log("lift: take off, starting at hover %d", math.floor(lift.hover + 0.5))
  end
  if holdingHeight() then
    local want = ud * CLIMB_SPEED
    if ud ~= 0 then
      lift.holdAlt = nil
      lift.stopping = true
    else
      -- Let go of up/down: first stop climbing or sinking, and only then
      -- take the height it stopped at as the new hover height (no
      -- springing back to where the key was let go).
      if lift.stopping and not lift.holdAlt then
        want = 0
        if math.abs(vy) < 0.3 then
          lift.stopping = false
          lift.holdAlt = alt
          log("lift: new hover height %.1f", alt)
        end
      else
        lift.stopping = false
        lift.holdAlt = lift.holdAlt or alt
        want = clamp(0.5 * (lift.holdAlt - alt), -CLIMB_SPEED, CLIMB_SPEED)
      end
    end
    -- Holding down while not moving: it's on the ground, so land.
    if ud < 0 and math.abs(vy) < 0.1 then
      lift.landedSince = lift.landedSince or now()
      if now() - lift.landedSince > 1.5 then
        lift.mode, lift.status, lift.landedSince = "off", "landed", nil
        log("lift: landed, lift off")
        setShift(0)
        setDown(0)
        lift.preDownHover = nil
        return
      end
    else
      lift.landedSince = nil
    end
    local err = want - vy
    -- Down thrusters: full power while Down is held (the lift still sets
    -- the speed), and a push when even no lift at all can't hold the height.
    -- The hover level learned while they push is thrown away afterwards.
    local down = 0
    if #downT > 0 and ud < 0 then
      down = DOWN_POWER
      lift.preDownHover = lift.preDownHover or lift.hover
    elseif #downT > 0 and err < 0 and lift.hover + LIFT_GAIN * err < 0 then
      down = clamp(-err * DOWN_GAIN, 0, DOWN_POWER)
    end
    if ud >= 0 and lift.preDownHover then
      lift.hover, lift.preDownHover = lift.preDownHover, nil
    end
    if down == 0 or ud < 0 then lift.hover = clamp(lift.hover + LIFT_LEARN * err * dt, 0, 256) end
    setShift(lift.hover + LIFT_GAIN * err)
    setDown(down)
    -- Remember the hover level once it has held steady for a while.
    if ud == 0 and math.abs(vy) < 0.2 then
      lift.steadySince = lift.steadySince or now()
      if now() - lift.steadySince > 5 then
        lift.steadySince = now()
        if not cfg.hover or math.abs(cfg.hover - lift.hover) > 2 then
          cfg.hover = math.floor(lift.hover + 0.5)
          saveConfig()
          log("lift: hover level learned %d", cfg.hover)
        end
      end
    else
      lift.steadySince = nil
    end
    lift.status = ud > 0 and "climbing" or ud < 0 and "descending"
      or string.format("hovering at %.1f", lift.holdAlt or alt)
    if downPower > 0 then lift.status = lift.status .. " (down " .. downPower .. ")" end
    if locked then lift.status = lift.status .. " - pulse lock" end
  else
    local base = cfg.hover or lift.hover or shift
    lift.hover = base
    setShift(base + ud * MANUAL_LIFT_STEP)
    setDown(ud < 0 and #downT > 0 and DOWN_POWER or 0)
    lift.status = ud > 0 and "more lift" or ud < 0 and "less lift" or "hover level"
  end
end

-- Runs all the time, under every screen.
local function liftLoop()
  local last = now()
  while true do
    local t = now()
    pollTypewriter()
    readHeight()
    liftStep(math.min(t - last, 0.5))
    last = t
    sleep(0.05)
  end
end

-- ---------- smart mode and autopilot ----------
-- cfg.smart (from Smart setup): left/right = how fast each turning group
-- spins the ship at full power (radians/s^2, signed), fwd/back = forward
-- and backward thrusters' push (blocks/s^2), offset = which way the ship's
-- nose points compared to its +X axis.

local function smartReady()
  return yaw ~= nil and cfg.smart ~= nil and cfg.smart.left ~= nil and cfg.smart.right ~= nil
end
local function navReady() return smartReady() and cfg.smart.fwd ~= nil end

-- Turning thruster powers for a yaw acceleration (radians/s^2).
local function turnFor(accel)
  local L, R = cfg.smart.left, cfg.smart.right
  if math.abs(accel) < 0.02 then return 0, 0 end
  if accel * L > 0 then return clamp(accel / L, 0, 1) * TURN_POWER, 0 end
  if accel * R > 0 then return 0, clamp(accel / R, 0, 1) * TURN_POWER end
  return 0, 0
end

-- Turn toward a heading; nil just stops the ship turning.
local function steerYaw(target)
  local wantRate = 0
  if target then wantRate = clamp(1.2 * wrapAngle(target - yaw), -TURN_RATE, TURN_RATE) end
  return turnFor((wantRate - yawRate) / 0.4)
end

local function noseYaw() return yaw + ((cfg.smart and cfg.smart.offset) or 0) end

-- Push directions (from Smart setup): for each thruster group, the
-- acceleration it gives at full power, in the ship's own frame (x along
-- the ship's +X axis, z across it), so it works for any layout.
local HOLD = {}   -- push directions and stop & hold (kept in one table: Lua allows 200 locals)
HOLD.GROUPS = { "forward", "back", "sleft", "sright" }
function HOLD.toBody(ax, az, y)
  local c, s = math.cos(-y), math.sin(-y)
  return ax * c - az * s, ax * s + az * c
end
function HOLD.ready()
  if not cfg.push or not yaw then return false end
  for _, g in ipairs(HOLD.GROUPS) do if cfg.push[g] and #group[g] > 0 then return true end end
  return false
end
-- Thruster powers that give (about) a wanted world acceleration.
function HOLD.pushFor(ax, az)
  local want = {}
  if not cfg.push or not yaw then return want end
  local bx, bz = HOLD.toBody(ax, az, yaw)
  for _, g in ipairs(HOLD.GROUPS) do
    local p = cfg.push[g]
    if p and #group[g] > 0 then
      local mag = math.sqrt(p.x * p.x + p.z * p.z)
      if mag > 0.02 then
        local along = (bx * p.x + bz * p.z) / mag   -- wanted accel along this group's push
        want[g] = clamp(along / mag, 0, 1) * 15
      end
    end
  end
  return want
end

-- The autopilot: { mode = "goto" or "hold", x, y, z, status }
local nav = nil
local landing = false   -- website "land": sink until the lift switches off
local remoteId, remoteState, remoteSent = nil, "off", 0   -- website link
local function navStop(why)
  if nav then log("%s off: %s", nav.mode == "brake" and "stop & hold" or "autopilot", why or "") end
  nav = nil
  allThrustOff()
end

-- B: stop every movement where it is, then hold that spot.
function HOLD.toggle()
  if nav and nav.mode == "brake" then navStop("B again") return end
  nav = { mode = "brake", phase = "stop", status = "stopping" }
  if lift.mode == "fly" then lift.holdAlt, lift.stopping = nil, true end
  log("stop & hold: on")
end

local function navLoop()
  local stoppedSince = nil
  while true do
    if landing then
      if lift.mode == "off" then
        landing = false
        lift.updown = 0
        log("landing: landed")
      else
        lift.updown = -1
      end
    end
    if nav and nav.mode == "brake" and posX then
      -- First kill the drift, then hold the spot where it stopped. The
      -- lift does the same up and down; turning holds the heading.
      local speed = math.sqrt(vx * vx + vz * vz)
      local ax, az
      if nav.phase == "stop" then
        ax, az = -HOLD_KD * vx, -HOLD_KD * vz
        if speed < 0.3 and math.abs(yawRate) < 0.05 then
          stoppedSince = stoppedSince or now()
          if now() - stoppedSince > 0.5 then
            nav.phase, nav.x, nav.z, nav.heading = "hold", posX, posZ, yaw
            nav.ix, nav.iz = 0, 0
            log("stop & hold: stopped, holding %.1f %.1f", posX, posZ)
          end
        else
          stoppedSince = nil
        end
      else
        local ex, ez = nav.x - posX, nav.z - posZ
        nav.ix = clamp(nav.ix + ex * 0.1, -8, 8)
        nav.iz = clamp(nav.iz + ez * 0.1, -8, 8)
        ax = HOLD_KP * ex + HOLD_KI * nav.ix - HOLD_KD * vx
        az = HOLD_KP * ez + HOLD_KI * nav.iz - HOLD_KD * vz
      end
      -- Tiny pushes only make it twitch.
      if math.sqrt(ax * ax + az * az) < 0.05 then ax, az = 0, 0 end
      local want = HOLD.pushFor(ax, az)
      if smartReady() then want.left, want.right = steerYaw(nav.heading) end
      setGroups(want)
      thrust = want.forward or 0
      if not HOLD.ready() then
        nav.status = "run Smart setup (S) first"
      elseif nav.phase == "stop" then
        nav.status = string.format("stopping, %.1f b/s", speed)
      else
        local dx, dz = nav.x - posX, nav.z - posZ
        nav.status = string.format("holding (%.1f off)", math.sqrt(dx * dx + dz * dz))
      end
    elseif nav and posX then
      if not navReady() then
        nav.status = "needs Smart setup first"
      else
        -- Height: take off if parked, then hold the target's Y (or this one).
        if lift.mode ~= "fly" and liftAvailable() then
          lift.mode = "fly"
          lift.hover = math.max(shift, cfg.hover or 0)
        end
        if lift.updown == 0 then lift.holdAlt = nav.y or lift.holdAlt or alt lift.stopping = false end

        local dx, dz = nav.x - posX, nav.z - posZ
        local dist = math.sqrt(dx * dx + dz * dz)
        local dirX, dirZ = 0, 0
        if dist > 0.01 then dirX, dirZ = dx / dist, dz / dist end
        -- The velocity it wants: toward the target, slow enough to stop in
        -- time, then gently into place.
        local fwdAcc = cfg.smart.fwd
        local backAcc = cfg.smart.back or 0
        local brake = math.max(0.2, math.min(fwdAcc, backAcc > 0.2 and backAcc or fwdAcc)) * 0.25
        local speed = math.min(NAV_SPEED, math.sqrt(2 * brake * math.max(0, dist - 0.5)), 0.4 * dist)
        local wx, wz = dirX * speed, dirZ * speed
        -- The ship can only push along its nose (forward or back), so it
        -- turns the nose along the change in velocity it needs, or the
        -- opposite way and uses the back thrusters, whichever is less turning.
        local ex, ez = wx - vx, wz - vz
        local need = math.sqrt(ex * ex + ez * ez)
        local heading = nav.course or yaw
        -- Once there, only turn again for a real drift, so it doesn't spin
        -- in place chasing tiny errors.
        local reaim = dist > NAV_ARRIVE and 0.25 or 0.8
        if need > reaim then
          local h = atan2(ez, ex) - cfg.smart.offset
          if backAcc > 0.2 and math.abs(wrapAngle(h + math.pi - yaw)) + 0.5 < math.abs(wrapAngle(h - yaw)) then
            h = h + math.pi
          end
          heading = wrapAngle(h)
          nav.course = heading
        end
        local l, r = steerYaw(heading)
        local ny = noseYaw()
        local along = ex * math.cos(ny) + ez * math.sin(ny)
        local lined = math.cos(wrapAngle(heading - yaw)) > 0.9
        local fwd, back = 0, 0
        if lined and along > 0.1 then
          fwd = clamp(along / (fwdAcc * 0.4), 0, 1) * 15
        elseif lined and along < -0.1 and backAcc > 0.2 then
          back = clamp(-along / (backAcc * 0.4), 0, 1) * BACK_POWER
        end
        setGroups({ forward = fwd, back = back, left = l, right = r })
        thrust = fwd

        local moving = math.sqrt(vx * vx + vz * vz)
        if nav.mode == "goto" then
          nav.status = string.format("%.0f blocks to go, %.1f b/s", dist, moving)
          if dist < NAV_ARRIVE and moving < 0.5 then
            stoppedSince = stoppedSince or now()
            if now() - stoppedSince > 1 then
              nav.mode, nav.status = "hold", "arrived - holding here"
              log("autopilot: arrived at %.1f %.1f", posX, posZ)
            end
          else
            stoppedSince = nil
          end
        else
          nav.status = string.format("holding position (%.1f off)", dist)
        end
      end
    end
    sleep(0.1)
  end
end

-- ---------- fuel and ship systems ----------
-- Fluid tanks (CC's fluid_storage; Advanced Peripherals adds the capacity),
-- the fuel inside each thruster, and every Create machine Create Avionics
-- reports on (speed, stress).

local tankNames, machineNames = {}, {}
for _, name in ipairs(peripheralNames()) do
  local types = { peripheral.getType(name) }
  local isTank, isMachine = false, false
  for _, ty in ipairs(types) do
    if ty == "fluid_storage" or ty == "fluid_tank" then isTank = true end
  end
  if not isTank and not THRUSTER_TYPES[types[1]] then
    local p = peripheral.wrap(name)
    if p and p.getSpeed and p.isOverstressed then isMachine = true end
  end
  if isTank then tankNames[#tankNames + 1] = name end
  if isMachine then machineNames[#machineNames + 1] = name end
end
table.sort(tankNames)
table.sort(machineNames)

-- fuel = { tank = mB, cap = mB or nil, inThrusters = mB, rate = mB/s burned
--          (negative while refilling), left = seconds or nil }
local fuel = { tank = 0, cap = nil, inThrusters = 0, rate = 0, left = nil, low = false }
local tankInfo, machineInfo = {}, {}
local fuelHistory = {}

local function isLava(name) return type(name) == "string" and name:find("lava") ~= nil end

local function readFuel()
  local total, cap, info = 0, 0, {}
  for _, name in ipairs(tankNames) do
    local amount, tcap, fluidName = 0, nil, nil
    local ok, list = pcall(peripheral.call, name, "tanks")
    if ok and type(list) == "table" then
      for _, f in pairs(list) do
        if type(f) == "table" and isLava(f.name) then amount = amount + (f.amount or 0) end
        if type(f) == "table" and f.name and not fluidName then fluidName = f.name end
      end
    end
    local ok2, i = pcall(peripheral.call, name, "info")
    if ok2 and type(i) == "table" and tonumber(i.capacity) then tcap = tonumber(i.capacity) end
    total = total + amount
    if tcap then cap = cap + tcap end
    info[#info + 1] = { name = name, amount = amount, cap = tcap, fluid = fluidName }
  end
  tankInfo = info
  local inThr = 0
  for _, t in ipairs(thrusters) do
    local ok, mb = pcall(t.p.getFuelAmountMb)
    if ok and type(mb) == "number" then inThr = inThr + mb end
  end
  fuel.tank, fuel.cap, fuel.inThrusters = total, cap > 0 and cap or nil, inThr
  -- Burn rate over the last ~10 seconds.
  local t = now()
  fuelHistory[#fuelHistory + 1] = { t = t, v = total + inThr }
  while #fuelHistory > 2 and t - fuelHistory[1].t > 10 do table.remove(fuelHistory, 1) end
  local first = fuelHistory[1]
  if t - first.t > 2 then
    fuel.rate = (first.v - (total + inThr)) / (t - first.t)
  end
  fuel.left = fuel.rate > 0.5 and (total + inThr) / fuel.rate or nil

  local mi = {}
  for _, name in ipairs(machineNames) do
    local ok, sp = pcall(peripheral.call, name, "getSpeed")
    local ok2, over = pcall(peripheral.call, name, "isOverstressed")
    mi[#mi + 1] = { name = name, speed = ok and sp or nil, over = ok2 and over == true }
  end
  machineInfo = mi
end

local function fuelKnown() return #tankNames > 0 end

local function timeText(sec)
  if not sec then return "-" end
  if sec >= 3600 then return string.format("%dh %02dm", math.floor(sec / 3600), math.floor(sec % 3600 / 60)) end
  if sec >= 60 then return string.format("%dm %02ds", math.floor(sec / 60), math.floor(sec % 60)) end
  return string.format("%ds", math.floor(sec))
end

-- Fuel alarm on a speaker: sounds while the tank is below FUEL_ALARM_PERCENT
-- until muted; re-arms once it refills a little above that.
local speaker = peripheral.find("speaker")
local fuelAlarm, alarmMuted = false, false
local function fuelPercent()
  if not fuel.cap or fuel.cap <= 0 then return nil end
  return fuel.tank / fuel.cap * 100
end
local function muteAlarm()
  if fuelAlarm and not alarmMuted then log("fuel alarm muted") end
  alarmMuted = true
end
-- Boost sounds: a launch whoosh when it starts, an engine rumble while
-- it's held, and a power-down note when it stops. boostOn is set by the
-- Fly screen while the boost key is held.
local boostOn = false
local function boostSoundLoop()
  local was = false
  local nextRumble = 0
  while true do
    if speaker then
      if boostOn and not was then
        pcall(speaker.playSound, "minecraft:entity.firework_rocket.launch", 2, 0.8)
        nextRumble = now() + 0.4
      elseif boostOn and now() >= nextRumble and not (fuelAlarm and not alarmMuted) then
        pcall(speaker.playNote, "didgeridoo", 2, 4)
        nextRumble = now() + 0.5
      elseif was and not boostOn then
        pcall(speaker.playNote, "bass", 2, 2)
      end
    end
    was = boostOn
    sleep(0.1)
  end
end

local function alarmLoop()
  while true do
    if fuelAlarm and not alarmMuted and speaker then
      pcall(speaker.playNote, "bit", 3, 20)
      sleep(0.15)
      pcall(speaker.playNote, "bit", 3, 12)
      sleep(0.15)
      pcall(speaker.playNote, "bell", 3, 24)
    end
    sleep(0.8)
  end
end

-- Reads fuel every second; warns, and lands before it runs dry.
local function fuelLoop()
  local warned = false
  while true do
    if fuelKnown() then
      readFuel()
      local pct = fuelPercent()
      if pct and FUEL_ALARM_PERCENT > 0 then
        if pct < FUEL_ALARM_PERCENT and not fuelAlarm then
          fuelAlarm = true
          log("FUEL ALARM: tank at %.0f%%", pct)
        elseif pct >= FUEL_ALARM_PERCENT + 3 and fuelAlarm then
          fuelAlarm, alarmMuted = false, false
          log("fuel alarm cleared: tank at %.0f%%", pct)
        end
      end
      local flying = lift.mode == "fly"
      fuel.low = flying and fuel.left ~= nil and fuel.left < LOW_FUEL_SECONDS
      if fuel.low and not warned then
        warned = true
        log("LOW FUEL: %d mB, %.1f mB/s, about %s left", fuel.tank + fuel.inThrusters, fuel.rate, timeText(fuel.left))
      elseif not fuel.low then
        warned = false
      end
      if flying and LOW_FUEL_LAND > 0 and fuel.left and fuel.left < LOW_FUEL_LAND and not landing then
        log("fuel nearly gone (%s left): landing", timeText(fuel.left))
        navStop("low fuel")
        landing = true
      end
    end
    sleep(1)
  end
end

-- ---------- screens ----------

-- Colors on an advanced computer; plain text on a basic one.
local COLOR = term.isColor ~= nil and term.isColor() == true
local W, H = 51, 19
do
  local ok, w, h = pcall(term.getSize)
  if ok and type(w) == "number" then W, H = w, h or 19 end
end
local C = {
  bar = colors.blue, key = colors.yellow, head = colors.lightBlue, dim = colors.lightGray,
  good = colors.lime, bad = colors.red, warn = colors.orange, sel = colors.gray,
}
local function fg(c) if COLOR then term.setTextColor(c) end end
local function bg(c) if COLOR then term.setBackgroundColor(c) end end

-- A bar: filled part in color, rest grey ([###---] without color).
local function meter(v, max, width, col)
  return function()
    local n = math.floor(clamp((v or 0) / max, 0, 1) * width + 0.5)
    if COLOR then
      bg(col or C.good) write(string.rep(" ", n))
      bg(colors.gray) write(string.rep(" ", width - n))
      bg(colors.black)
    else
      -- Brackets count toward the width so lines fit either way.
      local inner = width - 2
      local m = math.floor(clamp((v or 0) / max, 0, 1) * inner + 0.5)
      write("[" .. string.rep("#", m) .. string.rep("-", inner - m) .. "]")
    end
  end
end

-- Tappable areas on the current screen: { x1, x2, y, char = , key = }.
-- A tap turns into the same char (or key) event as typing it.
local buttons = {}
local tapAnywhere = false   -- pause(): any tap continues

local function cursor()
  local ok, x, y = pcall(term.getCursorPos)
  if ok and type(x) == "number" then return x, y end
end

-- Which key(s) a yellow key label stands for.
local function keysIn(text)
  if text == "Enter" then return { { key = keys.enter } } end
  if text:match("^%d%-%d$") then return {} end           -- a range like 1-9
  local list = {}
  for ch in text:gmatch("[^%s/]") do list[#list + 1] = { char = ch:lower() } end
  if #list > 1 and not text:find("/") then return {} end  -- a word, not keys
  return list
end

-- One line from pieces: "text", { color, "text" } or a meter. Yellow
-- (key) pieces become buttons that reach to the end of their label.
local function out(...)
  local current = nil
  for _, part in ipairs({ ... }) do
    local x, y = cursor()
    if type(part) == "table" then
      fg(part[1]) write(part[2]) fg(colors.white)
      if part[1] == C.key and x then
        current = nil
        local ks = keysIn(part[2])
        if #ks == 1 then
          current = { x1 = x, x2 = x + #part[2] - 1, y = y, char = ks[1].char, key = ks[1].key }
          buttons[#buttons + 1] = current
        elseif #ks > 1 then
          -- "+/-", "N/P": one button per key letter
          local i = 0
          for c in part[2]:gmatch(".") do
            if c ~= " " and c ~= "/" then
              buttons[#buttons + 1] = { x1 = x + i, x2 = x + i, y = y, char = c:lower() }
            end
            i = i + 1
          end
        end
      elseif current and x then
        current.x2 = x + #part[2] - 1
      end
    elseif type(part) == "function" then
      current = nil
      part()
    else
      write(tostring(part))
      if current and x then current.x2 = x + #tostring(part) - 1 end
    end
  end
  print("")
end

local function heading(text) out({ C.head, text }) end
local function hint(text) out({ C.dim, text }) end
-- " K  text  note" with the key in yellow.
local function keyLine(k, text, note)
  out(" ", { C.key, k }, "  ", text, note and { C.dim, "  " .. note } or "")
end
local function onOff(v) return v and { C.good, "ON " } or { C.dim, "off" } end

-- What the ship is doing, for the badge in the title bar.
local function liftBadge()
  if lift.mode == "off" then
    if lift.status == "landed" then return "LANDED", colors.gray end
    return "PARKED", colors.gray
  end
  local st = lift.status or ""
  if st:find("climb") or st == "more lift" then return "CLIMB", colors.cyan end
  if st:find("descend") or st == "less lift" then return "DESCEND", colors.orange end
  return "HOVER", colors.green
end

-- A button: " K label " on a grey background. The key letter is yellow.
-- action: { char = } or { key = } or { event = , value = }
local function chip(x, y, k, label, action, color)
  term.setCursorPos(x, y)
  local text = (k ~= "" and (" " .. k) or "") .. (label ~= "" and (" " .. label) or "") .. " "
  if COLOR then
    bg(color or colors.gray)
    write(" ")
    if k ~= "" then fg(C.key) write(k) fg(colors.white) end
    if label ~= "" then write((k ~= "" and " " or "") .. label) end
    write(" ")
    bg(colors.black)
  else
    text = "[" .. (k ~= "" and k or "") .. (label ~= "" and ((k ~= "" and " " or "") .. label) or "") .. "]"
    write(text)
  end
  buttons[#buttons + 1] = { x1 = x, x2 = x + #text - 1, y = y,
    char = action and action.char, key = action and action.key,
    event = action and action.event, value = action and action.value }
  return x + #text + 1
end

-- The button bar along the bottom: { { "Q", "Back", { char = "q" } }, ... }
local function footer(items)
  local cx, cy = cursor()
  term.setCursorPos(1, H)
  bg(colors.black)
  term.clearLine()
  local x = 2
  for _, it in ipairs(items) do
    if it[3] then x = chip(x, H, it[1], it[2], it[3]) else
      term.setCursorPos(x, H) fg(C.dim) write(it[2]) fg(colors.white)
      x = x + #it[2] + 1
    end
  end
  if cx then term.setCursorPos(cx, cy) end
end

-- A big two-line tile for the menu.
local function tile(x, y, w, k, title, desc)
  if COLOR then
    -- Checkerboard so touching tiles stay apart.
    local odd = (math.floor((y - 8) / 2) + (x > 2 and 1 or 0)) % 2 == 1
    bg(odd and colors.blue or colors.gray)
    for row = y, y + 1 do term.setCursorPos(x, row) write(string.rep(" ", w)) end
    term.setCursorPos(x + 1, y) fg(C.key) write(k) fg(colors.white) write("  " .. title)
    term.setCursorPos(x + 1, y + 1) fg(colors.lightGray) write(desc:sub(1, w - 2))
    fg(colors.white) bg(colors.black)
  else
    term.setCursorPos(x, y) write("[" .. k .. "] " .. title)
    term.setCursorPos(x + 1, y + 1) write(desc:sub(1, w - 2))
  end
  buttons[#buttons + 1] = { x1 = x, x2 = x + w - 1, y1 = y, y2 = y + 1, char = k:lower() }
end

-- cc-warship runs Fire Control next to this program and hands its
-- controls over (WARSHIP.guns); without it there are no guns.
-- (One table: the main chunk is near Lua's 200-locals limit.)
local war = { cacheAt = -1 }
function war.guns() return WARSHIP and WARSHIP.guns end
function war.state()
  local g = war.guns()
  if not g then return nil end
  if now() - war.cacheAt > 0.05 then
    local ok, st = pcall(g.state)
    war.cache, war.cacheAt = ok and st or nil, now()
  end
  return war.cache
end

local currentScreen = nil
local function screen(title)
  buttons = {}
  if title ~= currentScreen then
    currentScreen = title
    log("screen: %s", title)
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  local badge, bcol = liftBadge()
  local name = WARSHIP and "Warship" or ("Ship Pilot v" .. VERSION)
  local left = COLOR and (" " .. name .. "  \16 " .. title) or (" " .. name .. " > " .. title)
  local right = COLOR and (" " .. badge .. " ") or ("[" .. badge .. "]")
  local gs = war.state()
  local armedBadge = gs and gs.armed and (COLOR and " ARMED " or "[ARMED]") or ""
  bg(C.bar)
  write(left .. string.rep(" ", math.max(1, W - #left - #right - #armedBadge)))
  if armedBadge ~= "" then bg(colors.red) fg(colors.white) write(armedBadge) end
  bg(bcol) fg(colors.white) write(right)
  bg(colors.black)
  term.setCursorPos(1, 3)
end

-- cc-warship: everything the captain's display shows about flying.
function war.pilotState()
  local badge = liftBadge()
  local over = 0
  for _, m in ipairs(machineInfo) do if m.over then over = over + 1 end end
  local amount = fuel.tank + fuel.inThrusters
  return {
    badge = badge, liftStatus = lift.status, liftMode = lift.mode, lift = shift, hover = cfg.hover,
    alt = alt, vy = vy, x = posX, z = posZ, vx = vx, vz = vz,
    heading = yaw and noseYaw() or nil, turnRate = yawRate,
    throttle = FORWARD_POWER, power = groupPower, boost = boostOn,
    smart = cfg.smartOn, smartReady = smartReady(),
    nav = nav and { mode = nav.mode, status = nav.status, x = nav.x, y = nav.y, z = nav.z } or nil,
    fuel = fuelKnown() and { amount = amount, cap = fuel.cap, rate = fuel.rate, left = fuel.left, low = fuel.low } or nil,
    fuelAlarm = fuelAlarm, alarmMuted = alarmMuted, overstressed = over,
    screen = currentScreen, typewriter = typewriter ~= nil, relayError = relayError, onSable = onSable,
  }
end

-- A character typed on the typewriter (not the computer's keyboard).
local function typewriterChar(ch)
  local code = keys[ch]
  return code ~= nil and type(code) == "number" and fromTypewriter(code)
end

local function waitChar(allowed)
  while true do
    local _, ch = os.pullEvent("char")
    ch = ch:lower()
    if (not allowed or allowed:find(ch, 1, true)) and not typewriterChar(ch) then
      log("computer key: %s", ch)
      return ch
    end
  end
end

local function pause(msg)
  print("")
  hint(msg or "Press any key (or tap).")
  tapAnywhere = true
  os.pullEvent("char")
  tapAnywhere = false
end

local function liftLine()
  local s = string.format("Lift: %d/256 %s", math.floor(shift + 0.5), lift.status)
  if alt then s = s .. string.format("  y=%.1f %+.1f", alt, vy) end
  return s
end

-- " Fuel   [#####----]  6.4k mB  -12 mB/s  8m 20s"
local function fuelParts()
  local amount = fuel.tank + fuel.inThrusters
  local amt = amount >= 10000 and string.format("%.1fk mB", amount / 1000) or string.format("%d mB", amount)
  local rate = fuel.rate > 0.5 and string.format("  -%.0f/s", fuel.rate) or (fuel.rate < -0.5 and string.format("  +%.0f/s", -fuel.rate) or "")
  local col = fuel.low and C.bad or (fuel.cap and amount < fuel.cap * 0.2 and C.warn or C.good)
  local parts = {}
  if fuel.cap then parts[#parts + 1] = meter(amount, fuel.cap, 10, col) parts[#parts + 1] = " " end
  parts[#parts + 1] = { col, amt }
  parts[#parts + 1] = { C.dim, rate }
  if fuel.left then parts[#parts + 1] = { fuel.low and C.bad or colors.white, "  " .. timeText(fuel.left) .. " left" } end
  return parts
end

-- The guns' line on the Fly screen (cc-warship only).
function war.line()
  local gs = war.state()
  if gs then
    local firing = 0
    for _, m in ipairs(gs.mounts) do if m.state == "FIRE" or m.state == "FIRING" then firing = firing + 1 end end
    local t = gs.targets[1]
    return { gs.armed and { C.bad, " GUNS ARMED" } or { C.dim, " Guns safe" },
      t and string.format("  %s %.0fm", t.kind:sub(1, 12), t.d) or { C.dim, "  no targets" },
      firing > 0 and { C.bad, string.format("  firing %d", firing) } or "" }
  elseif WARSHIP and WARSHIP.gunsError then
    return { { C.bad, " Guns stopped" }, { C.dim, "  (menu A)" } }
  end
end

local function flyScreen()
  if not typewriter then screen("Fly") out({ C.warn, " No Linked Typewriter found." }) pause() return end
  local last, timer = now(), os.startTimer(0.05)
  -- The throttle starts at START_THROTTLE every time. The faster/slower
  -- keys step it once per press: each key event counts once, and that key
  -- is ignored until it's let go (key_up), so held keys, the typewriter's
  -- duplicate events and a key that looks stuck can't run it away.
  FORWARD_POWER = clamp(math.floor(START_THROTTLE + 0.5), 0, 15)
  log("throttle starts at %d", FORWARD_POWER)
  local latched = {}          -- key code -> true until its key_up
  local throttleSeen = cfg.throttleKeysSeen == true
  local course = yaw          -- smart mode: the heading to hold (the "lock")
  local lastTurnKey = 0
  local brakeI = 0            -- smart braking: integral term
  local backDir = nil         -- S: which way the ship was going when it was pressed
  local braking = false
  local frame = 0
  local function stepThrottle(dir)
    local v = clamp(math.floor(FORWARD_POWER + 0.5) + dir, 0, 15)
    if v ~= FORWARD_POWER then
      FORWARD_POWER = v
      log("throttle -> %d", v)
    end
  end
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "char" and typewriterChar(a:lower()) then ev = "typewriter_char" end
    if ev == "char" then
      local c = a:lower()
      if c == "q" then break
      elseif c == "+" or c == "=" then stepThrottle(1)
      elseif c == "-" then stepThrottle(-1)
      elseif c == "[" or c == "]" then
        TURN_POWER = clamp(math.floor(TURN_POWER + 0.5) + (c == "]" and 1 or -1), 1, 15)
        cfg.tune.TURN_POWER = TURN_POWER
        saveConfig()
        log("turning power -> %d", TURN_POWER)
      elseif c == "b" then
        HOLD.toggle()
      elseif c == "x" then
        muteAlarm()
      elseif c == "m" then
        cfg.smartOn = not cfg.smartOn
        course, brakeI = yaw, 0
        saveConfig()
        log("smart mode %s", cfg.smartOn and "on" or "off")
      end
    elseif ev == "turn_set" and type(a) == "number" then
      TURN_POWER = clamp(a, 1, 15)
      cfg.tune.TURN_POWER = TURN_POWER
      saveConfig()
      log("turning power -> %d (tapped)", TURN_POWER)
    elseif ev == "throttle_set" and type(a) == "number" then
      FORWARD_POWER = clamp(a, 0, 15)
      log("throttle -> %d (tapped)", FORWARD_POWER)
    elseif ev == "key" and a == keys[cfg.keys.brake] and not latched[a] and fromTypewriter(a) then
      latched[a] = now()
      HOLD.toggle()
    elseif ev == "key" then
      local dir = (a == keys[cfg.keys.faster] and 1) or (a == keys[cfg.keys.slower] and -1) or 0
      if dir ~= 0 and not latched[a] then
        latched[a] = now()
        stepThrottle(dir)
        if not throttleSeen then
          throttleSeen = true
          cfg.throttleKeysSeen = true
          saveConfig()
        end
      end
    elseif ev == "key_up" then
      latched[a] = nil
    end
    if ev == "timer" and a == timer then
      local t = now()
      local dt = math.min(t - last, 0.5)
      last = t
      frame = frame + 1
      -- A latch whose key_up never came: clear it once the key isn't held.
      for code, since in pairs(latched) do
        if not twHeld[code] and t - since > 0.5 then latched[code] = nil end
      end

      -- Each thruster group spools toward its power while its key is held.
      local turnL = down("left") and not down("right")
      local turnR = down("right") and not down("left")
      local target = {
        -- Boost (Ctrl): full forward power, whatever the throttle says.
        forward = down("boost") and 15 or (down("forward") and FORWARD_POWER or 0),
        -- Reverse and strafing always run at the throttle.
        back = 0,
        left = turnL and TURN_POWER or 0,
        right = turnR and TURN_POWER or 0,
        sleft = (down("sleft") and not down("sright")) and FORWARD_POWER or 0,
        sright = (down("sright") and not down("sleft")) and FORWARD_POWER or 0,
      }
      -- S: the throttle, plus more while the ship still carries forward
      -- momentum (never less than the throttle). "Forward" is the nose
      -- after Smart setup, otherwise the way it was moving when S went down.
      if down("back") then
        if not backDir then
          local sp = math.sqrt(vx * vx + vz * vz)
          backDir = sp > 0.3 and { x = vx / sp, z = vz / sp } or { x = 0, z = 0 }
        end
        local along
        if smartReady() then
          local ny = noseYaw()
          along = vx * math.cos(ny) + vz * math.sin(ny)
        else
          along = vx * backDir.x + vz * backDir.z
        end
        target.back = clamp(FORWARD_POWER + BACK_MOMENTUM * math.max(0, along), FORWARD_POWER, 15)
      else
        backDir = nil
      end
      -- Any movement key takes over from the autopilot or a landing.
      local manual = down("forward") or down("boost") or down("back") or turnL or turnR or down("up") or down("down")
        or down("sleft") or down("sright")
      if nav and manual then navStop("manual control") course = yaw end
      if landing and manual then landing = false log("landing cancelled by hand") end

      if cfg.smartOn and smartReady() and not nav then
        -- Heading lock. A/D turn the lock itself at SMART_TURN_RATE and the
        -- computer fires the turning thrusters to follow it, so the ship
        -- turns at a steady rate and stops where you let go (Sable doesn't
        -- slow a spin by itself, so full power would just keep speeding up).
        if course == nil then course = yaw end
        if turnL or turnR then
          lastTurnKey = t
          -- Which way "left" turns the ship comes from Smart setup.
          local leftDir = cfg.smart.left > 0 and 1 or -1
          local dirSign = turnL and leftDir or -leftDir
          course = course + dirSign * SMART_TURN_RATE * dt
          -- Don't let the lock run more than ~30 degrees ahead of the ship.
          course = yaw + clamp(wrapAngle(course - yaw), -0.5, 0.5)
        end
        course = wrapAngle(course)
        target.left, target.right = steerYaw(course)
        -- Smart braking: off the gas (neither forward nor back held), a PI
        -- controller on the speed along the nose brings the ship to a stop.
        braking = false
        if navReady() and not down("forward") and not down("boost") and not down("back") then
          local ny = noseYaw()
          local vAlong = vx * math.cos(ny) + vz * math.sin(ny)
          if math.abs(vAlong) > 0.15 then
            braking = true
            local e = -vAlong
            brakeI = clamp(brakeI + e * dt * 0.3, -2, 2)
            local accel = 0.8 * e + brakeI          -- blocks/s^2 wanted
            local backAcc = cfg.smart.back or 0
            if accel < 0 and backAcc > 0.2 then
              target.back = math.max(target.back, clamp(-accel / backAcc, 0, 1) * BACK_POWER)
            elseif accel > 0 then
              target.forward = math.max(target.forward, clamp(accel / cfg.smart.fwd, 0, 1) * 15)
            end
          else
            brakeI = 0
          end
        else
          brakeI = 0
        end
      else
        braking = false
      end

      if not nav then
        local step = THRUST_RAMP * dt
        local want = {}
        for _, g in ipairs(GROUPS) do
          -- Boost spools the forward thrusters up twice as fast.
          local st = (g == "forward" and down("boost")) and step * 2 or step
          want[g] = groupPower[g] + clamp(target[g] - groupPower[g], -st, st)
        end
        thrust = want.forward
        setGroups(want)
      end
      -- Relay turning (older setups): turning wins over backward.
      local move = nil
      if turnL then move = "left" elseif turnR then move = "right" elseif down("back") then move = "back" end
      applyMove(move)
      local ud = (down("up") and 1 or 0) - (down("down") and 1 or 0)
      if ud ~= 0 or not landing then lift.updown = ud end
      if down("boost") ~= boostOn then log("boost %s", down("boost") and "on" or "off") end
      boostOn = down("boost")

      -- Draw 10 times a second (control runs at 20), so monitors don't flicker.
      if frame % 2 == 0 then
        screen("Fly")
        local names = {}
        for _, act in ipairs(ACTIONS) do if down(act.id) then names[#names + 1] = act.label end end
        local gp = function(g) return math.floor(groupPower[g] + 0.5) end
        out(" Keys      ", #names > 0 and { C.key, table.concat(names, ", ") } or { C.dim, "none held" })
        -- Throttle: [-] bar [+]; tap a cell to jump to that level.
        local thr = math.floor(FORWARD_POWER + 0.5)
        local _, ty = cursor()
        ty = ty or 4
        term.setCursorPos(2, ty) write("Throttle ") fg(C.key) write(string.format("%2d", thr)) fg(colors.white)
        local cx = chip(14, ty, "-", "", { char = "-" })
        for i = 1, 15 do
          term.setCursorPos(cx + (i - 1) * 2, ty)
          if COLOR then
            bg(i <= thr and C.key or colors.gray) write(" ") bg(colors.black) write(" ")
          else
            write(i <= thr and "#" or "-") write(" ")
          end
          buttons[#buttons + 1] = { x1 = cx + (i - 1) * 2, x2 = cx + (i - 1) * 2 + 1, y = ty, event = "throttle_set", value = i }
        end
        chip(cx + 30, ty, "+", "", { char = "+" })
        -- Turning power: same control, saved between flights.
        local tp = math.floor(TURN_POWER + 0.5)
        local ry = ty + 1
        term.setCursorPos(2, ry) write("Turning  ") fg(C.head) write(string.format("%2d", tp)) fg(colors.white)
        local rx = chip(14, ry, "-", "", { char = "[" })
        for i = 1, 15 do
          term.setCursorPos(rx + (i - 1) * 2, ry)
          if COLOR then
            bg(i <= tp and C.head or colors.gray) write(" ") bg(colors.black) write(" ")
          else
            write(i <= tp and "#" or "-") write(" ")
          end
          buttons[#buttons + 1] = { x1 = rx + (i - 1) * 2, x2 = rx + (i - 1) * 2 + 1, y = ry, event = "turn_set", value = i }
        end
        chip(rx + 30, ry, "+", "", { char = "]" })
        term.setCursorPos(1, ry + 1)
        out(" Forward   ", meter(gp("forward"), 15, 10), string.format(" %2d", gp("forward")),
          "   Back    ", meter(gp("back"), 15, 10), string.format(" %2d", gp("back")))
        -- Strafe meters instead of turning ones on a ship with strafe but no turn thrusters.
        if #group.sleft + #group.sright > 0 and #group.left + #group.right == 0 then
          out(" Strafe L  ", meter(gp("sleft"), 15, 10), string.format(" %2d", gp("sleft")),
            "  Strafe R ", meter(gp("sright"), 15, 10), string.format(" %2d", gp("sright")))
        else
          out(" Turn L    ", meter(gp("left"), 15, 10), string.format(" %2d", gp("left")),
            "   Turn R  ", meter(gp("right"), 15, 10), string.format(" %2d", gp("right")))
        end
        print("")
        out(" Lift      ", meter(shift, 256, 11, C.head), string.format(" %3d/256  ", math.floor(shift + 0.5)),
          { C.dim, lift.status })
        if alt then
          local hs = math.sqrt(vx * vx + vz * vz)
          out(" Height    ", string.format("%.1f ", alt),
            { math.abs(vy) < 0.3 and C.dim or C.warn, string.format("%+.1f", vy) },
            string.format("   Speed %.1f b/s", hs),
            yaw and string.format("   Heading %3d", math.floor(math.deg(noseYaw()) % 360 + 0.5)) or "")
        end
        if fuelKnown() then out(" Fuel      ", table.unpack(fuelParts())) end
        print("")
        -- Status messages, most important first; at most five.
        local msgs = {}
        if fuelAlarm then
          msgs[#msgs + 1] = { { C.bad, " FUEL ALARM" }, { C.dim, string.format(" lava below %d%%%s", FUEL_ALARM_PERCENT,
            alarmMuted and " (muted)" or (speaker and "" or " (no speaker)")) } }
        end
        if fuel.low then
          msgs[#msgs + 1] = { { C.bad, " LOW FUEL" }, { C.dim, LOW_FUEL_LAND > 0 and string.format(" - lands itself at %ds left", LOW_FUEL_LAND) or "" } }
        end
        if down("boost") then msgs[#msgs + 1] = { { C.key, " BOOST" }, { C.dim, "  full power while Ctrl is held" } } end
        if landing then msgs[#msgs + 1] = { { C.warn, " Landing" }, { C.dim, "  (any movement key takes over)" } } end
        if nav then
          msgs[#msgs + 1] = { { C.good, nav.mode == "brake" and " Stop & hold: " or " Autopilot " }, nav.status or "",
            { C.dim, nav.mode == "brake" and "" or "  (any key takes over)" } }
        elseif cfg.smartOn then
          if not smartReady() then
            msgs[#msgs + 1] = { { C.warn, " Smart mode needs Smart setup (menu S)" } }
          else
            local turning = down("left") or down("right")
            msgs[#msgs + 1] = { { C.good, " Smart" }, course and string.format(turning and "  turning, lock %3d" or "  holding heading %3d",
              math.floor(math.deg(course + cfg.smart.offset) % 360 + 0.5)) or "",
              braking and { C.head, "   braking" } or "" }
          end
        end
        if relayError then msgs[#msgs + 1] = { { C.bad, " Relay error: " .. relayError } } end
        msgs[#msgs + 1] = war.line()
        if lastPulse and now() - lastPulse < 1.5 then msgs[#msgs + 1] = { { C.head, " Pulse sent" } } end
        if pulseMissingAt and now() - pulseMissingAt < 3 then
          msgs[#msgs + 1] = { { C.warn, " Pulse: no relay side set (Gearshifts, X)" } }
        end
        if not throttleSeen then
          msgs[#msgs + 1] = { { C.dim, " Q E F R B, Ctrl, arrows: bind them to a link" } }
          msgs[#msgs + 1] = { { C.dim, " frequency on the typewriter (sneak + right-click)." } }
        end
        for i = 1, math.min(#msgs, 6) do out(table.unpack(msgs[i])) end
        local items = { { "Q", "Menu", { char = "q" } }, { "-", "", { char = "-" } }, { "+", "", { char = "+" } },
          { "M", cfg.smartOn and "Smart ON" or "Smart off", { char = "m" } },
          { "B", nav and nav.mode == "brake" and "HOLDING" or "Hold", { char = "b" } } }
        if fuelAlarm and not alarmMuted then items[#items + 1] = { "X", "Mute alarm", { char = "x" } } end
        footer(items)
      end
      timer = os.startTimer(0.05)
    end
  end
  lift.updown = 0
  boostOn = false
  allThrustOff()
  applyMove(nil)
end

local function typewriterTest()
  local lastKey = nil
  while true do
    screen("Typewriter test")
    out(" Press keys on the ", { C.key, "typewriter" }, ".")
    print("")
    if lastKey then
      out(" Last key  ", { C.key, keyName(lastKey.code) }, { C.dim, string.format("  (code %d)", lastKey.code) })
      out(" From      ", { lastKey.from == "typewriter" and C.good or C.warn, lastKey.from })
      local bound = nil
      for _, act in ipairs(ACTIONS) do
        if keys[cfg.keys[act.id]] == lastKey.code then bound = act.label end
      end
      out(" Does      ", bound or { C.dim, "nothing (not bound)" })
    else
      out(" Last key  ", { C.dim, "none yet" })
    end
    local heldNames = {}
    for c in pairs(twHeld) do heldNames[#heldNames + 1] = keyName(c) end
    table.sort(heldNames)
    out(" Held now  ", #heldNames > 0 and { C.key, table.concat(heldNames, " ") } or { C.dim, "-" })
    print("")
    hint(" Keys from the computer keyboard show orange.")
    footer({ { "Q", "Back", { char = "q" } } })
    local timer = os.startTimer(0.25)
    local ev, a = os.pullEvent()
    if ev == "key" then
      lastKey = { code = a, from = fromTypewriter(a) and "typewriter" or "computer keyboard" }
      log("key event %s (%d) from %s", keyName(a), a, lastKey.from)
    elseif ev == "char" and a:lower() == "q" then
      return
    end
    os.cancelTimer(timer)
  end
end

local function keybinds()
  while true do
    screen("Keybinds")
    local KB = "1234567890abcd"
    for i, act in ipairs(ACTIONS) do
      out(" ", { C.key, KB:sub(i, i):upper() }, string.format("  %-13s ", act.label), { C.head, cfg.keys[act.id] })
    end
    print("")
    hint(" Tap an action to change its key.")
    footer({ { "R", "Reset to defaults", { char = "r" } }, { "Q", "Back", { char = "q" } } })
    local ch = waitChar(KB .. "rq")
    if ch == "q" then return end
    if ch == "r" then
      for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = name end
      saveConfig()
    else
      local act = ACTIONS[KB:find(ch, 1, true)]
      screen("Keybinds")
      out(" Press the new key for ", { C.key, act.label })
      out(" on the ", { C.key, "typewriter" }, ".")
      print("")
      hint(" The typewriter only passes on movement keys")
      hint(" and keys bound to a Redstone Link frequency.")
      print("")
      footer({ { "Q", "Cancel", { char = "q" } } })
      while true do
        local ev, a = os.pullEvent()
        if ev == "char" and a:lower() == "q" then break end
        if ev == "key" then
          if fromTypewriter(a) and keys.getName(a) then
            local name = keys.getName(a)
            -- Swap if another action already uses this key.
            for id, k in pairs(cfg.keys) do
              if k == name and id ~= act.id then cfg.keys[id] = cfg.keys[act.id] end
            end
            cfg.keys[act.id] = name
            saveConfig()
            break
          elseif a ~= keys.q then
            out({ C.warn, " That was the computer keyboard;" })
            out({ C.warn, " press it on the typewriter." })
          end
        end
      end
    end
  end
end

-- Switch relay sides by hand until the ship does what you want, then save
-- that combination as turn left, turn right or backward - or one side as
-- the pulse output.
local function gearshiftSetup()
  if nav then navStop("opened " .. "gearshiftSetup") end
  landing = false
  if #relays == 0 then screen("Gearshift setup") print("No Redstone Relay found.") pause() return end
  local list = {}
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do list[#list + 1] = { relay = r, side = side } end
  end
  local function key(o) return o.relay .. ":" .. o.side end
  local on = {}
  local function readOn()
    on = {}
    for i, o in ipairs(list) do on[i] = outState[key(o)] == true end
  end
  applyMove(nil)
  allRelaysOff()
  readOn()
  local page, pages = 0, math.ceil(#list / 9)
  local note = nil
  while true do
    screen("Gearshift setup")
    if relayError then out({ C.bad, " Relay error: " .. relayError:sub(1, W - 15) }) print("")
    elseif note then out({ C.warn, " " .. note }) print("")
    else
      hint(" Switch relay sides until the ship does what you")
      hint(" want, then save it. Easiest while hovering.")
    end
    note = nil
    local first = page * 9
    for i = 1, 9 do
      local o = list[first + i]
      if o then
        out(" ", { C.key, tostring(i) }, string.format("  %-20s ", (#relays > 1 and (o.relay .. " ") or "") .. o.side),
          onOff(on[first + i]), isPulse(o) and { C.head, "  Pulse" } or "")
      end
    end
    term.setCursorPos(1, 14)
    heading(" Save what's ON as:")
    out(" ", { C.key, "L" }, "  turn left   ", { C.dim, describe(cfg.moves.left) })
    out(" ", { C.key, "R" }, "  turn right  ", { C.dim, describe(cfg.moves.right) })
    out(" ", { C.key, "B" }, "  backward    ", { C.dim, describe(cfg.moves.back) })
    local pt = cfg.pulseTicks or PULSE_TICKS
    out(" ", { C.key, "X" }, "  Pulse       ",
      { C.dim, cfg.pulse and (cfg.pulse.relay:gsub("^redstone_", "") .. " " .. cfg.pulse.side) or "none" }, "  ",
      { C.key, "+/-" }, string.format(" %d tick%s  ", pt, pt == 1 and "" or "s"), { C.key, "T" }, " test")
    local items = { { "C", "All off", { char = "c" } } }
    if pages > 1 then
      items[#items + 1] = { "P", "", { char = "p" } }
      items[#items + 1] = { "", string.format("%d/%d", page + 1, pages) }
      items[#items + 1] = { "N", "", { char = "n" } }
    end
    items[#items + 1] = { "O", cfg.pulseBlip and "Pulse: blip on" or "Pulse: drop", { char = "o" } }
    items[#items + 1] = { "Q", "Done", { char = "q" } }
    footer(items)
    local ch = waitChar("123456789lrbxcnpq+=-to")
    local n = tonumber(ch)
    if n and list[first + n] then
      local i = first + n
      on[i] = not on[i]
      setOutput(list[i], on[i])
    elseif ch == "l" or ch == "r" or ch == "b" then
      local cur = {}
      for i, o in ipairs(list) do
        if on[i] and not isPulse(o) then cur[#cur + 1] = { relay = o.relay, side = o.side } end
      end
      local id = ch == "l" and "left" or ch == "r" and "right" or "back"
      cfg.moves[id] = cur
      saveConfig()
      log("gearshift setup: saved %s = %s", id, describe(cur))
    elseif ch == "x" then
      local cur = {}
      for i, o in ipairs(list) do if on[i] then cur[#cur + 1] = o end end
      if #cur == 0 then
        if cfg.pulse then log("gearshift setup: Pulse removed") end
        cfg.pulse = nil
        saveConfig()
        note = "Pulse removed (switch one side on, then X)."
      elseif #cur > 1 then
        note = "Switch exactly one side on for the pulse."
      else
        cfg.pulse = { relay = cur[1].relay, side = cur[1].side }
        -- It can't also be part of a move.
        for id, mv in pairs(cfg.moves) do
          local keep = {}
          for _, o in ipairs(mv) do if not isPulse(o) then keep[#keep + 1] = o end end
          cfg.moves[id] = keep
        end
        saveConfig()
        log("gearshift setup: Pulse = %s", describe({ cfg.pulse }))
      end
    elseif ch == "+" or ch == "=" or ch == "-" then
      cfg.pulseTicks = clamp((cfg.pulseTicks or PULSE_TICKS) + (ch == "-" and -1 or 1), 1, 40)
      saveConfig()
      log("gearshift setup: Pulse length %d ticks", cfg.pulseTicks)
    elseif ch == "o" then
      cfg.pulseBlip = not cfg.pulseBlip
      saveConfig()
      pulseOn()
      readOn()
      note = cfg.pulseBlip and "Pulse: off, blips on (for a toggle latch)." or "Pulse: on, drops off."
      log("gearshift setup: Pulse type %s", cfg.pulseBlip and "blip" or "drop")
    elseif ch == "t" then
      if not cfg.pulse then
        note = "Set the pulse side first: one side on, then X."
      else
        pulse()
        readOn()
        note = "Test pulse sent."
      end
    elseif ch == "c" then
      allRelaysOff()
      readOn()
    elseif ch == "n" and page + 1 < pages then
      page = page + 1
    elseif ch == "p" and page > 0 then
      page = page - 1
    elseif ch == "q" then
      allRelaysOff()
      outState = {}
      pulseOn()
      return
    end
  end
end

local function hoverCalibration()
  if nav then navStop("opened " .. "hoverCalibration") end
  landing = false
  if not liftAvailable() then
    screen("Hover calibration")
    out({ C.warn, " Nothing to lift with." })
    hint(" Give some thrusters the lift job in")
    hint(" Thruster setup (P) first.")
    pause()
    return
  end
  if holdingHeight() then
    -- Automatic: hold a height just above where it is now and wait for the
    -- lift to settle.
    lift.updown = 0
    if lift.mode ~= "fly" then
      lift.mode = "fly"
      lift.hover = math.max(shift, cfg.hover or 0)
    end
    local target = (lift.holdAlt or alt) + 3
    lift.holdAlt = target
    lift.stopping = false
    local steady, last, started = 0, now(), now()
    while true do
      local t = now()
      local dt = t - last
      last = t
      if math.abs(vy) < 0.15 and math.abs(alt - target) < 0.6 then steady = steady + dt else steady = 0 end
      screen("Hover calibration")
      hint(" Holding a height until the lift settles.")
      print("")
      out(" Target    ", string.format("%.1f", target), { C.dim, string.format("   now %.1f", alt) })
      out(" Lift      ", meter(shift, 256, 15, C.head), string.format(" %3d/256", math.floor(shift + 0.5)))
      out(" Vertical  ", { math.abs(vy) < 0.15 and C.good or C.warn, string.format("%+.2f b/s", vy) })
      out(" Steady    ", meter(steady, 5, 15), string.format(" %.1f / 5 s", math.min(steady, 5)))
      footer({ { "Q", "Stop", { char = "q" } } })
      if steady >= 5 then
        cfg.hover = math.floor(lift.hover + 0.5)
        saveConfig()
        log("hover calibration: saved %d", cfg.hover)
        screen("Hover calibration")
        out(" ", { C.good, "Saved!" }, string.format("  Hover level %d/256", cfg.hover))
        pause()
        return
      end
      if t - started > 90 then
        screen("Hover calibration")
        log("hover calibration: didn't settle (alt %.2f target %.2f vy %.2f shift %d)", alt, target, vy, shift)
        out({ C.warn, " It didn't settle in 90 seconds." })
        hint(" Nothing was changed. Try lowering Lift response")
        hint(" or Hover learning in Tuning (U).")
        pause()
        return
      end
      local timer = os.startTimer(0.25)
      local ev, a = os.pullEvent()
      if ev == "char" and a:lower() == "q" then return end
      os.cancelTimer(timer)
    end
  end
  -- By hand (no height reading): adjust until it just hovers.
  lift.mode = "off"
  local level = cfg.hover or shift
  while true do
    setShift(level)
    screen("Hover calibration (by hand)")
    hint(" No height reading: raise the lift until the ship")
    hint(" just floats, then save it.")
    print("")
    out(" Lift  ", meter(level, 256, 20, C.head), string.format(" %3d/256", math.floor(level + 0.5)))
    print("")
    footer({ { "-", "8", { char = "-" } }, { "[", "1", { char = "[" } }, { "]", "1", { char = "]" } },
      { "+", "8", { char = "+" } }, { "Enter", "Save", { key = keys.enter } }, { "Q", "Cancel", { char = "q" } } })
    local ev, a = os.pullEvent()
    if ev == "char" then
      if a == "+" or a == "=" then level = level + 8
      elseif a == "-" then level = level - 8
      elseif a == "]" then level = level + 1
      elseif a == "[" then level = level - 1
      elseif a:lower() == "q" then return end
      level = clamp(level, 0, 256)
    elseif ev == "key" and a == keys.enter then
      cfg.hover = math.floor(level + 0.5)
      lift.hover = cfg.hover
      saveConfig()
      lift.mode = "fly"
      return
    end
  end
end

local function manualTest()
  if nav then navStop("opened " .. "manualTest") end
  landing = false
  if #relays == 0 and #thrusters == 0 then screen("Manual test") print("No relays or thrusters found.") pause() return end
  local r = relays[1]
  local on = {}
  local thrustOn = false
  local prevMode = lift.mode
  lift.mode = "off"
  while true do
    screen("Manual test")
    if r then
      heading(" Relay " .. r)
      for i, side in ipairs(RELAY_SIDES) do
        out(" ", { C.key, tostring(i) }, string.format("  %-8s ", side), onOff(on[side]))
      end
    end
    heading(" Thrusters and lift")
    out(" ", { C.key, "T" }, string.format("  forward thrusters (%d)  ", #forwardT), onOff(thrustOn))
    out(" ", { C.key, "+/-" }, "  lift  ", meter(shift, 256, 15, C.head), string.format(" %3d/256", math.floor(shift + 0.5)))
    footer({ { "T", "Thrust", { char = "t" } }, { "-", "Lift", { char = "-" } }, { "+", "Lift", { char = "+" } },
      { "Q", "Back", { char = "q" } }, { "", "(all off)" } })
    local ch = waitChar("123456t+=-q")
    local n = tonumber(ch)
    if n and r then
      local side = RELAY_SIDES[n]
      on[side] = not on[side]
      setOutput({ relay = r, side = side }, on[side])
    elseif ch == "t" then
      thrustOn = not thrustOn
      setThrusters(thrustOn and FORWARD_POWER or 0)
    elseif ch == "+" or ch == "=" then
      setShift(shift + 16)
    elseif ch == "-" then
      setShift(shift - 16)
    elseif ch == "q" then
      allRelaysOff()
      setThrusters(0)
      -- Back to hovering from wherever the lift was left.
      if prevMode == "fly" then lift.mode, lift.hover = "fly", shift end
      return
    end
  end
end

-- Settings you can change from the computer, saved in ship.cfg.
local TUNE = {
  { name = "START_THROTTLE", label = "Start throttle", step = 1, min = 0, max = 15,
    help = { "Throttle each time Fly opens. The arrow", "keys change it while flying." } },
  { name = "BACK_POWER", label = "Backward power", step = 1, min = 0, max = 15,
    help = { "Most power reverse (S) uses; it follows", "the throttle up to this." } },
  { name = "TURN_POWER", label = "Turning power", step = 1, min = 0, max = 15,
    help = { "Turning thrusters' power. Lower it if", "the ship spins too fast." } },
  { name = "THRUST_RAMP", label = "Thrust spool-up", step = 5, min = 5, max = 200,
    help = { "How fast the thrusters spool up and", "down. Lower = gentler starts." } },
  { name = "CLIMB_SPEED", label = "Climb speed", step = 0.5, min = 0.5, max = 20,
    help = { "Blocks per second up or down while", "the key is held." } },
  { name = "LIFT_GAIN", label = "Lift response", step = 2, min = 1, max = 100,
    help = { "How hard the lift reacts to rising or", "sinking. Raise it if the ship sags or",
      "reacts slowly; lower it if it bounces." } },
  { name = "LIFT_LEARN", label = "Hover learning", step = 1, min = 0, max = 50,
    help = { "How fast it fine-tunes the hover level.", "Lower it if the ship slowly bobs up",
      "and down; raise it if it drifts." } },
  { name = "hover", label = "Hover level", step = 1, min = 0, max = 256,
    help = { "Lift level that hovers (0-256). Hover", "calibration and flying set it too." } },
  { name = "NAV_SPEED", label = "Autopilot speed", step = 1, min = 2, max = 40,
    help = { "Top speed when flying to coordinates", "(blocks per second)." } },
}
local TUNE_DEFAULT = {}
for _, t in ipairs(TUNE) do if t.name ~= "hover" then TUNE_DEFAULT[t.name] = _ENV[t.name] end end

local function tuneValue(t)
  if t.name == "hover" then return cfg.hover end
  return _ENV[t.name]
end

local function setTune(t, v)
  v = clamp(v, t.min, t.max)
  log("tuning: %s = %s", t.name, tostring(v))
  if t.name == "hover" then
    cfg.hover = math.floor(v + 0.5)
    if lift.mode == "fly" then lift.hover = cfg.hover end
  else
    _ENV[t.name] = v
    cfg.tune[t.name] = v
  end
  saveConfig()
end

local function tuning()
  local sel = 1
  while true do
    screen("Tuning")
    for i, t in ipairs(TUNE) do
      local v = tuneValue(t)
      if i == sel then bg(C.sel) end
      out(i == sel and "\16" or " ", { C.key, tostring(i) }, string.format(" %-17s ", t.label),
        v and { C.head, tostring(v) } or { C.dim, "-" }, string.rep(" ", 12))
      bg(colors.black)
    end
    print("")
    for _, line in ipairs(TUNE[sel].help) do hint(" " .. line) end
    print("")
    hint(" " .. liftLine())
    footer({ { "-", "Lower", { char = "-" } }, { "+", "Raise", { char = "+" } }, { "D", "Default", { char = "d" } },
      { "Q", "Back", { char = "q" } } })
    local timer = os.startTimer(0.5)
    local ev, a = os.pullEvent()
    os.cancelTimer(timer)
    if ev == "char" then
      local t = TUNE[sel]
      local n = tonumber(a)
      if n and TUNE[n] then sel = n
      elseif a == "+" or a == "=" then setTune(t, (tuneValue(t) or 0) + t.step)
      elseif a == "-" then setTune(t, (tuneValue(t) or 0) - t.step)
      elseif a:lower() == "d" and TUNE_DEFAULT[t.name] then
        _ENV[t.name] = TUNE_DEFAULT[t.name]
        cfg.tune[t.name] = nil
        saveConfig()
      elseif a:lower() == "q" then return end
    end
  end
end

-- Mark each thruster as lift, forward or off.
local function thrusterSetup()
  if nav then navStop("opened " .. "thrusterSetup") end
  landing = false
  if #thrusters == 0 then screen("Thruster setup") print("No thrusters found.") pause() return end
  local page, sel = 0, 1
  local KEYROLE = { w = "forward", s = "back", a = "left", d = "right", j = "sleft", l = "sright",
    u = "lift", v = "down", o = "off" }
  while true do
    screen("Thruster setup")
    local first = page * 9
    for i = 1, 9 do
      local t = thrusters[first + i]
      if t then
        local r = roleOf(t)
        local col = (r == "lift" or r == "down") and C.head or r == "move" and C.good or r == "unset" and C.warn or C.dim
        if sel == first + i then bg(C.sel) end
        out(sel == first + i and "\16" or " ", { C.key, tostring(i) }, string.format(" %-14s ", t.name),
          { col, roleText(t) }, string.rep(" ", 6))
        bg(colors.black)
      end
    end
    hint(" Pick one (1-9), then switch its jobs on/off;")
    hint(" it can have several, e.g. turn left + backward.")
    out(" ", { C.key, "W" }, " forward  ", { C.key, "S" }, " backward  ", { C.key, "A" }, " turn left  ",
      { C.key, "D" }, " turn right")
    out(" ", { C.key, "J" }, " strafe left  ", { C.key, "L" }, " strafe right")
    out(" ", { C.key, "U" }, " lift     ", { C.key, "V" }, " down      ", { C.key, "O" }, " off")
    local items = { { "T", "Test-fire", { char = "t" } }, { "X", "All lift", { char = "x" } } }
    if #thrusters > 9 then
      items[#items + 1] = { "P", "", { char = "p" } }
      items[#items + 1] = { "", string.format("%d/%d", page + 1, math.ceil(#thrusters / 9)) }
      items[#items + 1] = { "N", "", { char = "n" } }
    end
    items[#items + 1] = { "Q", "Back", { char = "q" } }
    footer(items)
    local ch = waitChar("123456789wsadjluvotxnpq")
    local n = tonumber(ch)
    local t = thrusters[sel]
    if n and thrusters[first + n] then
      sel = first + n
    elseif KEYROLE[ch] then
      local job = KEYROLE[ch]
      if MOVE[job] then
        -- Movement jobs switch on and off; a thruster can have several.
        local list, has = {}, false
        for g in pairs(rolesOf(t)) do
          if g == job then has = true else list[#list + 1] = g end
        end
        if not has then list[#list + 1] = job end
        cfg.roles[t.name] = #list > 0 and list or "off"
      else
        cfg.roles[t.name] = job
      end
      saveConfig()
      log("thruster setup: %s = %s", t.name, roleText(t))
    elseif ch == "x" then
      for _, x in ipairs(thrusters) do cfg.roles[x.name] = "lift" end
      saveConfig()
      log("thruster setup: all lift")
    elseif ch == "t" then
      log("thruster setup: test-fire %s", t.name)
      pcall(t.p.setPower, 15)
      sleep(1)
      pcall(t.p.setPower, 0)
    elseif ch == "n" and (page + 1) * 9 < #thrusters then
      page, sel = page + 1, (page + 1) * 9 + 1
    elseif ch == "p" and page > 0 then
      page, sel = page - 1, (page - 1) * 9 + 1
    elseif ch == "q" then
      -- Start everything from a clean state with the new roles.
      for _, x in ipairs(thrusters) do pcall(x.p.setPower, 0) end
      sortThrusters()
      liftSent, groupSent, thrusterSent, downSent = {}, {}, {}, {}
      downPower = 0
      groupPower = { forward = 0, back = 0, left = 0, right = 0, sleft = 0, sright = 0 }
      thrust = 0
      setShift(shift)
      return
    end
  end
end

-- Fires the thrusters briefly to learn how they turn and push the ship.
local function smartSetup()
  if nav then navStop("opened " .. "smartSetup") end
  landing = false
  screen("Smart setup")
  if not onSable or not yaw then
    out({ C.warn, " Needs the ship's position and heading (CC: Sable)." })
    pause()
    return
  end
  local pushGroups = {}
  for _, g in ipairs(HOLD.GROUPS) do if #group[g] > 0 then pushGroups[#pushGroups + 1] = g end end
  local turning = #group.left > 0 and #group.right > 0
  if #pushGroups == 0 then
    out({ C.warn, " Needs forward, backward or strafe thrusters" })
    out({ C.warn, " (Thruster setup)." })
    pause()
    return
  end
  hint(turning and " The ship turns a little left and right, then" or " The ship gets a short push from each group of")
  hint(turning and " gets a short push from each thruster group," or " thrusters (forward, back, strafe) and stops")
  hint(turning and " stopping in between." or " in between.")
  hint(" Do this hovering, with some room around it.")
  footer({ { "Enter", "Start", { key = keys.enter } }, { "Q", "Cancel", { char = "q" } } })
  while true do
    local ev, a = os.pullEvent()
    if ev == "char" and a:lower() == "q" then return end
    if ev == "key" and a == keys.enter then break end
  end
  if nav then navStop("smart setup") end
  -- Keep hovering through all of it.
  if lift.mode ~= "fly" and liftAvailable() then
    lift.mode, lift.hover = "fly", math.max(shift, cfg.hover or 0)
  end
  lift.updown = 0
  local function show(step)
    screen("Smart setup")
    out(" ", { C.key, step })
    print("")
    out(" Heading  ", string.format("%3d", math.floor(math.deg(yaw) % 360 + 0.5)),
      { C.dim, string.format("   turning %+.2f rad/s", yawRate) })
    out(" Speed    ", string.format("%.1f b/s", math.sqrt(vx * vx + vz * vz)))
  end
  -- Full power for a moment, then measure the change once it spins down.
  local function pulse(step, want, seconds)
    show(step)
    local r0, v0x, v0z, y0, t0 = yawRate, vx, vz, yaw, now()
    setGroups(want)
    while now() - t0 < seconds do sleep(0.1) show(step) end
    setGroups({})
    local held = now() - t0
    sleep(0.4)
    return (yawRate - r0) / held, (vx - v0x) / held, (vz - v0z) / held, y0
  end
  -- Brake with whatever has been learned so far.
  local function settle(step, seconds)
    local t0 = now()
    while now() - t0 < seconds do
      local want = HOLD.pushFor(-HOLD_KD * vx, -HOLD_KD * vz)
      if smartReady() then want.left, want.right = steerYaw(nil) end
      setGroups(want)
      if math.abs(yawRate) < 0.03 and math.sqrt(vx * vx + vz * vz) < 0.3 and now() - t0 > 1 then break end
      sleep(0.1)
      show(step)
    end
    setGroups({})
  end

  local newSmart = {}
  local L, R = nil, nil
  if turning then
    L = pulse("Turning left...", { left = 15 }, 0.6)
    R = pulse("Turning right...", { right = 15 }, 0.6)
    log("smart setup: left %.3f right %.3f rad/s^2", L, R)
    if math.abs(L) < 0.02 or math.abs(R) < 0.02 or L * R > 0 then
      screen("Smart setup")
      out({ C.bad, " The turning thrusters didn't turn the ship" })
      out({ C.bad, " opposite ways." })
      hint(string.format(" Measured: left %.2f, right %.2f", L, R))
      hint(" Check Thruster setup, then try again.")
      pause()
      return
    end
    newSmart.left, newSmart.right = L, R
    cfg.smart = { left = L, right = R, offset = cfg.smart and cfg.smart.offset }
    settle("Stopping the turn...", 6)
  end

  local LABEL = { forward = "Forward", back = "Backward", sleft = "Strafe left", sright = "Strafe right" }
  cfg.push = {}
  local results = {}
  for _, g in ipairs(pushGroups) do
    local _, ax, az, y0 = pulse(LABEL[g] .. "...", { [g] = 15 }, 1.0)
    local bx, bz = HOLD.toBody(ax, az, y0)
    local mag = math.sqrt(bx * bx + bz * bz)
    log("smart setup: %s pushes %.2f b/s^2 (body %.2f, %.2f)", g, mag, bx, bz)
    if mag >= 0.05 then cfg.push[g] = { x = bx, z = bz } end
    results[#results + 1] = { g = g, mag = mag }
    settle("Stopping...", 6)
  end
  -- The nose is where the forward thrusters push (smart mode, autopilot).
  local f = cfg.push.forward
  if f then
    newSmart.offset = atan2(f.z, f.x)
    newSmart.fwd = math.sqrt(f.x * f.x + f.z * f.z)
    local b = cfg.push.back
    if b then
      local backAcc = -(b.x * math.cos(newSmart.offset) + b.z * math.sin(newSmart.offset))
      newSmart.back = backAcc > 0.05 and backAcc or nil
    end
  end
  cfg.smart = newSmart
  saveConfig()
  screen("Smart setup")
  out(" ", { C.good, "Done!" })
  print("")
  if L then out(" Turning      ", string.format("left %.2f  right %.2f rad/s2", L, R)) end
  for _, r in ipairs(results) do
    out(string.format(" %-13s", LABEL[r.g]), r.mag >= 0.05 and string.format("%.2f b/s2", r.mag)
      or { C.warn, "didn't move the ship" })
  end
  print("")
  hint(" B on the Fly screen (or the typewriter) stops")
  hint(" the ship and holds it in place.")
  if smartReady() and newSmart.fwd then hint(" Smart mode and Go to can be used too.") end
  pause()
end

-- Shows the autopilot working; it keeps flying from the menu too.
local function autopilotScreen()
  while true do
    screen("Autopilot")
    if not nav then
      out({ C.dim, " The autopilot is off." })
      footer({ { "Q", "Menu", { char = "q" } } })
      waitChar("q")
      return
    end
    out(" Target    ", string.format("%d  %s  %d", nav.x, nav.y and tostring(nav.y) or "-", nav.z),
      { C.dim, nav.y and "" or "  (keeps height)" })
    if posX then
      local d = math.sqrt((nav.x - posX) ^ 2 + (nav.z - posZ) ^ 2)
      out(" Distance  ", string.format("%.1f blocks", d))
      out(" Position  ", string.format("%.0f  %.0f  %.0f", posX, alt or 0, posZ))
      out(" Speed     ", string.format("%.1f b/s", math.sqrt(vx * vx + vz * vz)))
    end
    print("")
    out(" Status    ", { nav.mode == "hold" and C.good or C.head, nav.status or "starting" })
    print("")
    hint(" Moving any key on the typewriter takes over.")
    footer({ { "S", "Stop here", { char = "s" } }, { "C", "Cancel", { char = "c" } }, { "Q", "Menu", { char = "q" } } })
    local timer = os.startTimer(0.25)
    local ev, a = os.pullEvent()
    os.cancelTimer(timer)
    if ev == "char" then
      local c = a:lower()
      if c == "q" then return
      elseif c == "s" and posX then
        nav = { mode = "hold", x = math.floor(posX + 0.5), z = math.floor(posZ + 0.5), y = alt and math.floor(alt + 0.5) }
        log("autopilot: hold here")
      elseif c == "c" then
        navStop("cancelled")
      end
    end
  end
end

-- Type or tap in coordinates, then fly there.
local function gotoScreen()
  local f = { x = "", y = "", z = "" }
  if nav then f.x, f.y, f.z = tostring(nav.x), nav.y and tostring(nav.y) or "", tostring(nav.z) end
  local order, cur, msg = { "x", "z", "y" }, "x", nil
  while true do
    screen("Go to")
    if not navReady() then out({ C.warn, " Run Smart setup first (menu)." }) else
      hint(" Type or tap the coordinates. Y can stay empty.") end
    print("")
    local _, y0 = cursor()
    y0 = y0 or 5
    local x = 2
    for _, k in ipairs(order) do
      local val = f[k] ~= "" and f[k] or (k == "y" and "keep" or "")
      term.setCursorPos(x, y0)
      fg(cur == k and C.key or colors.white) write(k:upper() .. " ") fg(colors.white)
      local box = string.format(" %-7s", val):sub(1, 8)
      if COLOR then bg(cur == k and colors.gray or colors.black) write(box) bg(colors.black)
      else write(cur == k and ("[" .. box .. "]") or (" " .. box .. " ")) end
      buttons[#buttons + 1] = { x1 = x, x2 = x + 10, y = y0, char = k }
      x = x + 16
    end
    if posX then
      term.setCursorPos(2, y0 + 1)
      fg(C.dim) write(string.format("now %.0f  %.0f  %.0f", posX, alt or 0, posZ)) fg(colors.white)
    end
    -- Keypad
    local rows = { { "7", "8", "9" }, { "4", "5", "6" }, { "1", "2", "3" }, { "-", "0", "<" } }
    for i, row in ipairs(rows) do
      local kx = 4
      for _, k in ipairs(row) do
        if k == "<" then kx = chip(kx, y0 + 2 + i * 2 - 1, "<", "", { key = keys.backspace })
        else kx = chip(kx, y0 + 2 + i * 2 - 1, k, "", { char = k }) end
        kx = kx + 1
      end
    end
    chip(24, y0 + 3, "H", "Here", { char = "h" })
    chip(24, y0 + 5, "N", "Next field", { char = "n" })
    chip(24, y0 + 7, "C", "Clear", { char = "c" })
    if msg then term.setCursorPos(24, y0 + 9) fg(C.warn) write(msg) fg(colors.white) end
    footer({ { "G", "Go", { char = "g" } }, { "Q", "Cancel", { char = "q" } } })
    msg = nil
    local ev, a = os.pullEvent()
    if ev == "char" then
      local c = a:lower()
      if c:match("[%d]") or (c == "-" and f[cur] == "") then
        if #f[cur] < 7 then f[cur] = f[cur] .. c end
      elseif c == "x" or c == "y" or c == "z" then cur = c
      elseif c == "n" then
        for i, k in ipairs(order) do if k == cur then cur = order[i % 3 + 1] break end end
      elseif c == "h" and posX then
        f.x, f.z = tostring(math.floor(posX + 0.5)), tostring(math.floor(posZ + 0.5))
        f.y = alt and tostring(math.floor(alt + 0.5)) or ""
      elseif c == "c" then f[cur] = ""
      elseif c == "q" then return
      elseif c == "g" then
        local gx, gy, gz = tonumber(f.x), tonumber(f.y), tonumber(f.z)
        if not gx or not gz then msg = "X and Z needed"
        elseif not navReady() then msg = "Smart setup first"
        else
          nav = { mode = "goto", x = gx, y = gy, z = gz }
          log("autopilot: go to %s %s %s", gx, tostring(gy), gz)
          autopilotScreen()
          return
        end
      end
    elseif ev == "key" then
      if a == keys.backspace then f[cur] = f[cur]:sub(1, -2)
      elseif a == keys.enter then os.queueEvent("char", "g")
      elseif a == keys.tab then os.queueEvent("char", "n") end
    end
  end
end

-- Fuel tanks, fuel in the thrusters, and every Create machine's speed.
local function systemsScreen()
  while true do
    screen("Systems")
    if fuelKnown() then
      heading(" Fuel")
      for _, t in ipairs(tankInfo) do
        local nm = t.name:gsub("^.*:", ""):gsub("_block_entity", ""):sub(1, 18)
        out(string.format(" %-18s ", nm), t.cap and meter(t.amount, t.cap, 10, isLava(t.fluid) and C.good or C.warn) or "",
          string.format(" %d", t.amount), t.cap and { C.dim, string.format("/%d mB", t.cap) } or { C.dim, " mB" },
          (t.fluid and not isLava(t.fluid)) and { C.warn, "  " .. t.fluid } or "")
      end
      out(" in thrusters       ", string.format("%d mB", fuel.inThrusters))
      out(" burn rate          ", fuel.rate > 0.5 and string.format("%.1f mB/s", fuel.rate)
        or (fuel.rate < -0.5 and { C.good, string.format("refilling %.1f mB/s", -fuel.rate) } or { C.dim, "not burning" }),
        fuel.left and { fuel.low and C.bad or colors.white, "   " .. timeText(fuel.left) .. " left" } or "")
    else
      hint(" No fluid tanks connected.")
    end
    if #machineInfo > 0 then
      print("")
      heading(" Machines")
      for i, m in ipairs(machineInfo) do
        if i > 7 then hint(string.format(" ... and %d more", #machineInfo - 7)) break end
        local nm = m.name:gsub("^[^:]*:", ""):sub(1, 22)
        local state
        if m.over then state = { C.bad, "OVERSTRESSED" }
        elseif not m.speed or math.abs(m.speed) < 0.01 then state = { C.warn, "stopped" }
        else state = { C.good, string.format("%d rpm", math.floor(m.speed + 0.5)) } end
        out(string.format(" %-22s ", nm), state)
      end
    end
    local items = { { "Q", "Back", { char = "q" } } }
    if fuelAlarm and not alarmMuted then items[#items + 1] = { "X", "Mute fuel alarm", { char = "x" } } end
    footer(items)
    local timer = os.startTimer(1)
    local ev, a = os.pullEvent()
    os.cancelTimer(timer)
    if ev == "char" and a:lower() == "q" then return end
    if ev == "char" and a:lower() == "x" then muteAlarm() end
  end
end

-- cc-warship: Fire Control's status and controls. The radar aims; Fire
-- Control fires when a shot would hit and never through your own ship.
function war.screen()
  local msg, msgAt = nil, 0
  while true do
    screen("Auto cannons")
    local g, gs = war.guns(), war.state()
    if not gs then
      if WARSHIP.gunsError then
        out({ C.bad, " Fire Control stopped:" })
        out({ C.dim, " " .. tostring(WARSHIP.gunsError):match("^[^\n]*"):sub(1, W - 2) })
        print("")
        hint(" R restarts it.")
      else
        hint(" Fire Control is starting (needs fire_control.lua 1.4.0+).")
      end
      footer({ { "R", "Restart", { char = "r" } }, { "Q", "Menu", { char = "q" } } })
    else
      out(" Cannons   ", gs.armed and { C.bad, "ARMED" } or { C.good, "SAFE" },
        { C.dim, gs.armed and "  firing when a shot would hit" or "  watching only" })
      out(" Radar     ", gs.radar and { C.head, gs.radar } or { C.bad, "MISSING" },
        gs.radarError and { C.bad, ("  " .. tostring(gs.radarError)):sub(1, W - 13 - #(gs.radar or "MISSING")) } or "")
      out(" Rounds    ", string.format("%.1f b/t ", gs.speed), { C.dim, gs.speedLearned and "learned" or
        (gs.learning and string.format("learning %d/5", gs.learning) or "SHOT_SPEED") },
        { C.dim, gs.autocannon and "   autocannon" or "   big cannon" })
      out(" Ship      ", string.format("%.0f m/s   rock ", gs.shipSpeed),
        { gs.rock > gs.maxRock and C.warn or colors.white, string.format("%.1f", gs.rock) },
        gs.rock > gs.maxRock and { C.warn, "  holding fire" } or "")
      if #gs.targets == 0 then
        out(" Targets   ", { C.dim, "none in range" })
      else
        for i, t in ipairs(gs.targets) do
          out(i == 1 and " Targets " or "         ", i == 1 and { C.warn, "> " } or "  ",
            { i == 1 and C.warn or C.dim, string.format("%s %s %.0fm %.0fm/s", t.cat, t.kind:sub(1, 12), t.d, t.speed) },
            t.ago > 1 and { C.dim, string.format(" (%.0fs ago)", t.ago) } or "")
        end
      end
      local _, y = cursor()
      y = (y or 10) + 1
      if #gs.mounts == 0 then
        term.setCursorPos(1, y)
        out({ C.bad, " No cannon mounts found (right-click the modems)." })
      end
      -- Cannons: one column, two when there are many.
      local rows = math.max(1, H - 1 - y)
      local cols = #gs.mounts > rows and 2 or 1
      if cols == 2 then rows = math.min(rows, math.ceil(#gs.mounts / 2)) end
      local cw = cols == 2 and 25 or W - 2
      for i, m in ipairs(gs.mounts) do
        local col, row = math.floor((i - 1) / rows), (i - 1) % rows
        if col >= cols then break end
        term.setCursorPos(2 + col * cw, y + row)
        local st = m.state or ""
        local c = colors.lightGray
        if st == "FIRE" or st == "FIRING" then c = C.bad
        elseif st == "ON TARGET" then c = C.good
        elseif st == "points at own ship" or st == "own ship in line" then c = C.warn end
        local tag = m.side == "left" and "L" or (m.side == "right" and "R" or "?")
        local line = string.format("%-8s %s %s", m.name:gsub("^cannon_", ""):sub(1, 8), tag, st)
        if cols == 1 and m.miss and m.miss < 1e6 then
          line = line .. string.format("  miss %.0f", m.miss)
          if m.miss > gs.hitRadius and m.dy and math.abs(m.dy) > m.miss * 0.5 then line = line .. (m.dy > 0 and " high" or " low") end
        end
        fg(c) write(line:sub(1, cw - 1)) fg(colors.white)
      end
      term.setCursorPos(2, y - 1)
      if gs.fireControllers > 0 then
        fg(C.bad) write("Fire Controller on the network: remove it!") fg(colors.white)
      elseif msg and now() - msgAt < 2 then
        fg(C.head) write(msg) fg(colors.white)
      end
      footer({ { "A", gs.armed and "Safe" or "Arm", { char = "a" } }, { "F", "Fire", { char = "f" } },
        { "X", "Ignore", { char = "x" } }, { "U", "Unignore", { char = "u" } }, { "Q", "Menu", { char = "q" } } })
    end
    local timer = os.startTimer(0.25)
    local ev, a = os.pullEvent()
    os.cancelTimer(timer)
    -- Typewriter letters fly the ship; only the computer's keys (and taps) work here.
    if ev == "char" and not typewriterChar(a:lower()) then
      local c = a:lower()
      if c == "q" then return
      elseif c == "r" and not gs and WARSHIP.restartGuns then WARSHIP.restartGuns()
      elseif g and gs then
        if c == "a" then
          g.toggle()
          log("guns %s", gs.armed and "safe" or "ARMED")
        elseif c == "f" then g.fire() msg, msgAt = "Firing every cannon that's clear of the ship", now()
        elseif c == "x" then
          msg, msgAt = g.ignoreNearest() and "Nearest target ignored for good" or "No target to ignore", now()
        elseif c == "u" then g.unignoreAll() msg, msgAt = "Nothing ignored now", now() end
        war.cacheAt = -1
      end
    end
  end
end

local function menu()
  while true do
    screen("Menu")
    local unset = 0
    for _, t in ipairs(thrusters) do if roleOf(t) == "unset" then unset = unset + 1 end end
    out(" Typewriter ", typewriter and { C.good, "connected" } or { C.bad, "MISSING" },
      "   Height ", onSable and { C.good, "Sable" } or { C.warn, "none" },
      #relays > 0 and { C.dim, string.format("   %d relay%s", #relays, #relays == 1 and "" or "s") } or "")
    if unset > 0 then
      out(" Thrusters  ", { C.warn, string.format("%d without a job - tap Thrusters", unset) })
    else
      local parts = { #liftT .. " lift", #group.forward .. " fwd", #group.back .. " back" }
      if #group.left + #group.right > 0 then parts[#parts + 1] = #group.left .. "+" .. #group.right .. " turn" end
      if #group.sleft + #group.sright > 0 then parts[#parts + 1] = #group.sleft .. "+" .. #group.sright .. " strafe" end
      if #downT > 0 then parts[#parts + 1] = #downT .. " down" end
      out(" Thrusters  ", { C.head, table.concat(parts, "  "):sub(1, W - 12) })
    end
    out(" Hover      ", cfg.hover and string.format("%d/256", cfg.hover) or { C.warn, "not calibrated - tap Hover" },
      transmission and { C.dim, "   (lift transmission)" } or "")
    out(" Lift       ", meter(shift, 256, 14, C.head), " ", { C.dim, lift.status },
      alt and { C.dim, string.format("  y %.1f", alt) } or "")
    local trouble = false
    for _, m in ipairs(machineInfo) do if m.over then trouble = true end end
    if fuelKnown() then
      out(" ", { C.key, "Y" }, " ", fuelAlarm and { C.bad, "ALARM   " } or "Fuel     ", table.unpack(fuelParts()))
    elseif #machineNames > 0 then
      out(" ", { C.key, "Y" }, " Systems  ", { C.dim, #machineNames .. " machines" })
    end

    local L, R, w = 2, 27, 24
    tile(L, 8, w, "F", "Fly", "fly with typewriter")
    if WARSHIP then
      local gs = war.state()
      tile(R, 8, w, "A", "Auto cannons", not gs and (WARSHIP.gunsError and "STOPPED - tap to see" or "starting")
        or string.format("%s  %d gun%s  %d tgt", gs.armed and "ARMED" or "safe", #gs.mounts,
          #gs.mounts == 1 and "" or "s", #gs.targets))
    else
      tile(R, 8, w, "A", "Go to", nav and "autopilot ON" or "autopilot to coords")
    end
    tile(L, 10, w, "P", "Thrusters", "jobs for each thruster")
    tile(R, 10, w, "S", "Smart setup", navReady() and "done - redo any time" or "needed for smart/auto")
    tile(L, 12, w, "H", "Hover", "calibrate hovering")
    tile(R, 12, w, "U", "Tuning", "power, speed, response")
    tile(L, 14, w, "K", "Keybinds", "typewriter keys")
    tile(R, 14, w, "G", "Gearshifts", "relay turning, pulse")
    tile(L, 16, w, "T", "Typewriter test", "see what keys arrive")
    tile(R, 16, w, "M", "Manual test", "relays, thrust, lift")
    if REMOTE and remoteId then
      term.setCursorPos(2, 18)
      fg(C.dim) write("Website code ") fg(C.key) write(remoteId)
      fg(remoteState == "connected" and C.good or C.warn) write("  " .. remoteState) fg(colors.white)
    end
    term.setCursorPos(2, H)
    if relayError then
      fg(C.bad) write(("Relay error: " .. relayError):sub(1, W - 2)) fg(colors.white)
    end
    if fuelAlarm and not alarmMuted then
      footer({ { "X", "Mute fuel alarm", { char = "x" } }, { "", string.format("lava below %d%%", FUEL_ALARM_PERCENT) } })
    end
    local ch = waitChar("ftkghupmasyx")
    if ch == "f" then flyScreen()
    elseif ch == "a" and WARSHIP then war.screen()
    elseif ch == "a" then if nav then autopilotScreen() else gotoScreen() end
    elseif ch == "s" then smartSetup()
    elseif ch == "y" then systemsScreen()
    elseif ch == "x" then muteAlarm()
    elseif ch == "t" then typewriterTest()
    elseif ch == "k" then keybinds()
    elseif ch == "g" then gearshiftSetup()
    elseif ch == "h" then hoverCalibration()
    elseif ch == "u" then tuning()
    elseif ch == "p" then thrusterSetup()
    elseif ch == "m" then manualTest() end
  end
end

-- ---------- website control ----------
-- Commands come in on ntfy.sh topic shippilot-<code>-cmd over a websocket;
-- status updates go out on shippilot-<code>-tel. Anyone with the code can
-- send commands, so treat it like a password.

local wantUpdate = false
local trail = {}   -- position 4 times a second since the last update

local function remoteTopic(kind) return "shippilot-" .. remoteId .. "-" .. kind end

local function loadRemoteId()
  local path = "ship_remote_id"
  if fs.exists(path) then
    local h = fs.open(path, "r")
    local id = h.readAll():match("%w+")
    h.close()
    if id then return id end
  end
  math.randomseed(os.epoch("utc"))
  local chars, id = "abcdefghjkmnpqrstuvwxyz23456789", ""
  for _ = 1, 8 do
    local i = math.random(1, #chars)
    id = id .. chars:sub(i, i)
  end
  local h = fs.open(path, "w")
  h.write(id)
  h.close()
  return id
end

-- Today's update count, kept in a file so a reboot doesn't reset it.
local function countSent()
  local today = os.date("!%Y-%m-%d")
  local day, n = nil, 0
  if fs.exists("ship_remote_count") then
    local h = fs.open("ship_remote_count", "r")
    day, n = h.readAll():match("(%S+)%s+(%d+)")
    h.close()
  end
  return today, (day == today and tonumber(n) or 0)
end

local function r1(v) return math.floor(v * 10 + 0.5) / 10 end

local function telemetry()
  local badge = liftBadge()
  local t = {
    v = VERSION, m = currentScreen or "-", b = badge, ls = lift.status,
    smart = cfg.smartOn == true, ready = navReady(), thr = math.floor(FORWARD_POWER + 0.5),
    hover = cfg.hover, sent = remoteSent + 1, limit = REMOTE_DAILY_LIMIT, ts = os.epoch("utc"),
  }
  if posX then
    t.p = { r1(posX), r1(alt or 0), r1(posZ) }
    t.vel = { r1(vx), r1(vy), r1(vz) }
  end
  if yaw then t.hd = math.floor(math.deg(noseYaw()) % 360 + 0.5) end
  if fuelKnown() then
    t.fuel = { a = fuel.tank + fuel.inThrusters, c = fuel.cap, r = r1(fuel.rate),
      l = fuel.left and math.floor(fuel.left) or nil, low = fuel.low, alarm = fuelAlarm, muted = alarmMuted }
  end
  if landing then t.landing = true end
  if nav then t.nav = { mode = nav.mode, x = nav.x, y = nav.y, z = nav.z, s = nav.status } end
  local h, nowT = {}, now()
  for i, smp in ipairs(trail) do h[i] = { math.floor((nowT - smp.t) * 100 + 0.5) / 100, smp.x, smp.z, smp.y } end
  if #h > 0 then t.h = h end
  return t
end

local function sendUpdate()
  local today, n = countSent()
  remoteSent = n
  if n >= REMOTE_DAILY_LIMIT then
    remoteState = "daily limit reached"
    return false
  end
  local ok, res = pcall(http.post, "https://ntfy.sh/" .. remoteTopic("tel"), textutils.serializeJSON(telemetry()))
  if ok and res then
    res.close()
    trail = {}
    remoteSent = n + 1
    local f = fs.open("ship_remote_count", "w")
    f.write(today .. " " .. remoteSent)
    f.close()
    return true
  end
  return false
end

local function handleCommand(c)
  log("website: %s", tostring(c.c))
  local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
  if c.c == "goto" and x and z then
    if navReady() then
      nav = { mode = "goto", x = x, y = y, z = z }
      landing = false
    end
  elseif c.c == "hold" and posX then
    if navReady() then
      nav = { mode = "hold", x = math.floor(posX + 0.5), z = math.floor(posZ + 0.5), y = alt and math.floor(alt + 0.5) }
      landing = false
    end
  elseif c.c == "cancel" then
    navStop("website")
  elseif c.c == "land" then
    navStop("website land")
    landing = true
  elseif c.c == "smart" then
    cfg.smartOn = c.on == true
    saveConfig()
  elseif c.c == "mute" then
    muteAlarm()
  elseif c.c == "throttle" and tonumber(c.v) then
    FORWARD_POWER = clamp(math.floor(tonumber(c.v) + 0.5), 0, 15)
  end
  wantUpdate = true   -- every command (including "ping") gets a fresh update
end

local function remoteLoop()
  while true do
    remoteState = "connecting"
    local ok, ws = pcall(http.websocket, "wss://ntfy.sh/" .. remoteTopic("cmd") .. "/ws")
    if ok and ws then
      remoteState = "connected"
      wantUpdate = true
      while true do
        -- ntfy sends a keepalive about every 45 s.
        local ok2, msg = pcall(ws.receive, 60)
        if not ok2 or not msg then break end
        local ev = textutils.unserializeJSON(msg)
        if type(ev) == "table" and ev.event == "message" and ev.message then
          local cmd = textutils.unserializeJSON(ev.message)
          -- Ignore stale commands (over a minute old).
          if type(cmd) == "table" and (not cmd.ts or math.abs(os.epoch("utc") - cmd.ts) < 60000) then
            handleCommand(cmd)
          end
        end
      end
      pcall(ws.close)
    end
    remoteState = "offline, retrying"
    sleep(10)
  end
end

-- Status updates: on changes, every TELEMETRY_SECONDS while moving, and
-- when the website asks. Positions are kept 4 times a second in between.
local function telemetryLoop()
  local lastSent, lastShape = -math.huge, nil
  while true do
    local moving = nav ~= nil or (posX and (math.abs(vx) + math.abs(vz) + math.abs(vy)) > 0.3)
    if moving and posX then
      trail[#trail + 1] = { t = now(), x = r1(posX), z = r1(posZ), y = r1(alt or 0) }
      if #trail > 60 then table.remove(trail, 1) end
    end
    local shape = tostring(currentScreen) .. liftBadge() .. tostring(cfg.smartOn) .. (nav and nav.mode or "-")
      .. tostring(fuelAlarm) .. tostring(alarmMuted)
    local due = wantUpdate or (shape ~= lastShape and now() - lastSent > 2)
      or (moving and now() - lastSent > TELEMETRY_SECONDS)
    if due and remoteState == "connected" then
      wantUpdate = false
      if sendUpdate() then lastSent, lastShape = now(), shape end
    end
    sleep(0.25)
  end
end


-- ---------- main ----------

local args = { ... }
loadConfig()
sortThrusters()
setDown(0)
pulseOn()
if #liftT > 0 then
  -- Already flying when the program starts (e.g. after a reboot): pick up
  -- the lift thrusters' current power and hover.
  local total = 0
  for _, t in ipairs(liftT) do
    local ok, v = pcall(t.p.getPower)
    v = ok and type(v) == "number" and v or 0
    if v > 1 then v = v / 15 end   -- 0-15 or 0-1, whichever it reports
    total = total + v
    liftSent[t.name] = math.floor(v * 15 + 0.5)
  end
  shift = total / #liftT * 256
  if shift > 1 then lift.mode, lift.hover = "fly", shift end
elseif transmission then
  pcall(transmission.setTransmissionMode, "incremental")
  local ok, cur = pcall(transmission.getShiftLevel)
  shift = ok and type(cur) == "number" and cur or 0
  sentShift = math.floor(shift + 0.5)
  -- Already flying when the program starts (e.g. after a reboot): hover.
  if shift > 0 then lift.mode, lift.hover = "fly", shift end
end

-- Turns clicks on the computer and taps on the monitor into key presses.
local function touchLoop()
  while true do
    local ev, a, x, y = os.pullEvent()
    if ev == "mouse_click" or ev == "monitor_touch" then
      local hit = nil
      for _, b in ipairs(buttons) do
        if y >= (b.y1 or b.y) and y <= (b.y2 or b.y) and x >= b.x1 and x <= b.x2 then hit = b break end
      end
      if hit then
        log("tap %d,%d -> %s", x, y, hit.char or hit.event or "enter")
        if hit.event then os.queueEvent(hit.event, hit.value)
        elseif hit.key then os.queueEvent("key", hit.key, false)
        elseif hit.char then os.queueEvent("char", hit.char) end
      elseif tapAnywhere then
        os.queueEvent("char", " ")
      end
    end
  end
end

-- An Advanced Monitor, if there is one big enough, shows the same screens.
local monitor = nil
local function mirrorToMonitor()
  local m = peripheral.find("monitor", function(_, p) return p.isColor and p.isColor() end)
  if not m then return end
  for _, scale in ipairs({ 1, 0.5 }) do
    m.setTextScale(scale)
    local mw, mh = m.getSize()
    if mw >= W and mh >= 19 then
      monitor = m
      break
    end
  end
  if not monitor then
    log("monitor too small for the screens, not used")
    return
  end
  m.setBackgroundColor(colors.black)
  m.clear()
  local native = term.current()
  -- Every drawing call goes to both; sizes and colors come from the computer.
  local both = {}
  for k, f in pairs(native) do
    if type(f) == "function" then
      both[k] = function(...)
        pcall(m[k], ...)
        return f(...)
      end
    end
  end
  both.getSize = native.getSize
  both.isColor = native.isColor
  both.isColour = native.isColour
  term.redirect(both)
  log("mirroring to a %dx%d monitor", m.getSize())
end

-- A line of numbers 5 times a second while flying, once a second otherwise.
local function sampleLoop()
  while true do
    readVelocity()
    local held = {}
    for _, act in ipairs(ACTIONS) do if down(act.id) then held[#held + 1] = act.id end end
    log("S %-6s keys=%s thrust=%d move=%s lift=%s %d/256 hover=%s y=%s vy=%+.2f vel=%s pos=%s yaw=%s rate=%+.2f v=%.1f,%.1f nav=%s",
      currentScreen or "-", #held > 0 and table.concat(held, "+") or "-", math.floor(thrust + 0.5),
      currentMove or "-", lift.mode, math.floor(shift + 0.5), lift.hover and tostring(math.floor(lift.hover + 0.5)) or "-",
      alt and string.format("%.2f", alt) or "-", vy, velText(),
      posX and string.format("%.1f,%.1f", posX, posZ) or "-", yaw and string.format("%.0f", math.deg(yaw)) or "-",
      yawRate, vx, vz, nav and (nav.mode .. " " .. tostring(nav.status)) or "-")
    sleep(currentScreen == "Fly" and 0.5 or 2)
  end
end

local function ui()
  if args[1] == "fly" then flyScreen() end
  menu()
end

-- Start the log (keeping the previous run as ship.log.old).
pcall(function()
  if fs.exists(LOG_FILE) then
    if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
    fs.move(LOG_FILE, LOG_FILE .. ".old")
  end
  logFile = fs.open(LOG_FILE, "w")
end)
log("Ship Pilot v%s", VERSION)
for _, name in ipairs(peripheralNames()) do log("peripheral %s: %s", name, tostring(peripheral.getType(name))) end
for _, v in ipairs(velSensors) do log("velocity sensor %s axis %s", v.name, tostring(v.axis)) end
for _, t in ipairs(thrusters) do log("thruster %s role %s", t.name, roleText(t)) end
for _, n in ipairs(tankNames) do log("fuel tank %s", n) end
log("speaker: %s", speaker and "found" or "none")
for _, n in ipairs(machineNames) do log("machine %s", n) end
log("Sable: %s  transmission start level: %d  lift mode: %s", tostring(onSable), math.floor(shift + 0.5), lift.mode)
log("config: %s", textutils.serialize(cfg):gsub("%s+", " "))
log("settings: FORWARD_POWER=%s THRUST_RAMP=%s ALT_HOLD=%s CLIMB_SPEED=%s LIFT_GAIN=%s LIFT_LEARN=%s MANUAL_LIFT_STEP=%s",
  tostring(FORWARD_POWER), tostring(THRUST_RAMP), tostring(ALT_HOLD), tostring(CLIMB_SPEED),
  tostring(LIFT_GAIN), tostring(LIFT_LEARN), tostring(MANUAL_LIFT_STEP))

pcall(mirrorToMonitor)
REMOTE = REMOTE and http ~= nil and http.websocket ~= nil
if REMOTE then remoteId = loadRemoteId() log("website code %s", remoteId) end
-- The pulse key on the typewriter (any screen but the key screens): the output
-- drops for PULSE_TICKS ticks. Once per press.
local function pulseLoop()
  local latchedAt = nil
  while true do
    local ev, code = os.pullEvent()
    local pk = keys[cfg.keys.pulse]
    if latchedAt and not twHeld[pk] and now() - latchedAt > 0.5 then latchedAt = nil end
    if ev == "key" and code == pk and not latchedAt and currentScreen ~= "Keybinds"
        and currentScreen ~= "Typewriter test" and fromTypewriter(code) then
      latchedAt = now()
      if cfg.pulse then pulse() else
        pulseMissingAt = now()
        log("pulse key pressed but no pulse output is set")
      end
    elseif ev == "key_up" and code == pk then
      latchedAt = nil
    end
  end
end

-- cc-warship: the arm key on the typewriter (any screen but the key
-- screens) arms or safes the cannons. Once per press; a speaker beeps
-- high for armed, low for safe.
function war.armLoop()
  local latched = false
  while true do
    local ev, code = os.pullEvent()
    local ak = keys[cfg.keys.arm]
    if ev == "key" and code == ak and not latched and currentScreen ~= "Keybinds"
        and currentScreen ~= "Typewriter test" and fromTypewriter(code) then
      latched = true
      local g = war.guns()
      if g then
        g.toggle()
        war.cacheAt = -1
        local gs = war.state()
        log("guns %s (typewriter)", gs and gs.armed and "ARMED" or "safe")
        if speaker then pcall(speaker.playNote, "pling", 1, gs and gs.armed and 18 or 6) end
      else
        log("arm key pressed but Fire Control isn't running")
      end
    elseif ev == "key_up" and code == ak then
      latched = false
    end
  end
end

local loops = { liftLoop, ui, sampleLoop, touchLoop, navLoop, fuelLoop, alarmLoop, boostSoundLoop, pulseLoop }
-- cc-warship: the captain's display reads the pilot's state through this.
if WARSHIP then
  WARSHIP.pilot = { version = VERSION, state = war.pilotState }
  loops[#loops + 1] = war.armLoop
end
if REMOTE then loops[#loops + 1] = remoteLoop loops[#loops + 1] = telemetryLoop end
local ok, err = xpcall(function() parallel.waitForAny(table.unpack(loops)) end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
if logFile then logFile.close() end
-- Thrusters and turning off; the lift stays where it is so the ship doesn't drop.
allThrustOff()
pcall(setDown, 0)
applyMove(nil)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  print("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in ship.log (pastebin put ship.log).")
end
print("Thrusters and turning are off. Lift is still at " .. math.floor(shift + 0.5) .. "/256.")
