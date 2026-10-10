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

VERSION = "2.10.0"

-- ======================== SETTINGS ===========================
-- Change these from the Tuning menu (U) on the computer; what you set
-- there is saved in ship.cfg and overrides the values below.

START_THROTTLE = 5      -- throttle each time Fly opens (0-15)
FORWARD_POWER = 15      -- throttle: thruster power while forward is held (0-15);
                        -- the faster/slower keys change it while flying
BACK_POWER = 15         -- backward thrusters' power (0-15)
TURN_POWER = 15         -- turning thrusters' power (0-15)
THRUST_RAMP = 30        -- how fast thrusters spool up and down (power per second)
ALT_HOLD = true         -- hold height on a Sable ship (needs CC: Sable)
CLIMB_SPEED = 4         -- blocks per second up or down while the key is held
LIFT_GAIN = 20          -- lift change per block/s of vertical speed error
LIFT_LEARN = 8          -- how fast it fine-tunes the hover level
-- Without altitude hold: how far up/down keys move the lift from the hover level.
MANUAL_LIFT_STEP = 40

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
}
local DEFAULT_KEYS = { forward = "w", back = "s", left = "a", right = "d", up = "space", down = "leftShift",
  faster = "up", slower = "down" }

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function now() return os.epoch("utc") / 1000 end

-- ---------- hardware ----------

local typewriter = peripheral.find("linked_typewriter")
local transmission = peripheral.find("redstone_transmission")
local thrusters, relays = {}, {}   -- thrusters: { name = , p = }
for _, name in ipairs(peripheral.getNames()) do
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
for _, name in ipairs(peripheral.getNames()) do
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
local LOG_FILE, LOG_LIMIT = "ship.log", 400000
local logFile, logBytes, logFull = nil, 0, false
local logStart = now()
local function log(fmt, ...)
  if not logFile or logFull then return end
  local line = string.format("%8.2f ", now() - logStart) .. string.format(fmt, ...)
  logBytes = logBytes + #line + 1
  if logBytes > LOG_LIMIT then
    logFull = true
    line = "log full, stopped writing"
  end
  logFile.writeLine(line)
  logFile.flush()
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
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serialize(cfg))
  h.close()
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

local function allRelaysOff()
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do setOutput({ relay = r, side = side }, false) end
  end
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
local GROUPS = { "forward", "back", "left", "right" }
local ROLE_LABEL = { lift = "lift", forward = "forward", back = "backward", left = "turn left",
  right = "turn right", off = "off", unset = "NOT SET" }
local MOVE = { forward = true, back = true, left = true, right = true }
local group = { forward = {}, back = {}, left = {}, right = {} }
local forwardT, liftT, moveT = group.forward, {}, {}

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
local function roleOf(t)    -- "lift", "off", "move" or "unset"
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
  group = { forward = {}, back = {}, left = {}, right = {} }
  liftT, moveT = {}, {}
  for _, t in ipairs(thrusters) do
    local r = roleOf(t)
    if r == "lift" then
      liftT[#liftT + 1] = t
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
local groupPower = { forward = 0, back = 0, left = 0, right = 0 }
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
  setGroups({ forward = power, back = groupPower.back, left = groupPower.left, right = groupPower.right })
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
local function readHeight()
  if not onSable then return end
  local ok, pose = pcall(sublevel.getLogicalPose)
  if not ok or not pose then return end
  local y, t = pose.position.y, now()
  posX, posZ = pose.position.x, pose.position.z
  if alt and lastAltT and t > lastAltT then
    vy = vy * 0.5 + (y - alt) / (t - lastAltT) * 0.5
  end
  alt, lastAltT = y, t
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
  if lift.mode == "off" then
    if ud <= 0 then return end
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
    else
      lift.holdAlt = lift.holdAlt or alt
      want = clamp(0.5 * (lift.holdAlt - alt), -CLIMB_SPEED, CLIMB_SPEED)
    end
    -- Holding down while not moving: it's on the ground, so land.
    if ud < 0 and math.abs(vy) < 0.1 then
      lift.landedSince = lift.landedSince or now()
      if now() - lift.landedSince > 1.5 then
        lift.mode, lift.status, lift.landedSince = "off", "landed", nil
        log("lift: landed, lift off")
        setShift(0)
        return
      end
    else
      lift.landedSince = nil
    end
    local err = want - vy
    lift.hover = clamp(lift.hover + LIFT_LEARN * err * dt, 0, 256)
    setShift(lift.hover + LIFT_GAIN * err)
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
  else
    local base = cfg.hover or lift.hover or shift
    lift.hover = base
    setShift(base + ud * MANUAL_LIFT_STEP)
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
    bg(colors.gray)
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
  local left = COLOR and (" Ship Pilot  \16 " .. title) or (" Ship Pilot > " .. title)
  local right = COLOR and (" " .. badge .. " ") or ("[" .. badge .. "]")
  bg(C.bar)
  write(left .. string.rep(" ", math.max(1, W - #left - #right)))
  bg(bcol) fg(colors.white) write(right)
  bg(colors.black)
  term.setCursorPos(1, 3)
end

local function waitChar(allowed)
  while true do
    local _, ch = os.pullEvent("char")
    ch = ch:lower()
    if not allowed or allowed:find(ch, 1, true) then
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

local function flyScreen()
  if not typewriter then screen("Fly") print("No Linked Typewriter found.") pause() return end
  local last, timer = now(), os.startTimer(0.05)
  -- The throttle starts at START_THROTTLE every time, and the arrow keys
  -- move it one step per tap only: no repeating, so a key that looks stuck
  -- down can't run it to 0.
  FORWARD_POWER = clamp(math.floor(START_THROTTLE + 0.5), 0, 15)
  log("throttle starts at %d", FORWARD_POWER)
  local throttleDir = 0
  local function stepThrottle(dir)
    local v = clamp(math.floor(FORWARD_POWER + 0.5) + dir, 0, 15)
    if v ~= FORWARD_POWER then
      FORWARD_POWER = v
      log("throttle -> %d", v)
    end
  end
  while true do
    local ev, a = os.pullEvent()
    -- Throttle from the screen: - / + on the computer, or tap the bar.
    if ev == "char" then
      local c = a:lower()
      if c == "q" then break
      elseif c == "+" or c == "=" then stepThrottle(1)
      elseif c == "-" then stepThrottle(-1) end
    elseif ev == "throttle_set" and type(a) == "number" then
      FORWARD_POWER = clamp(a, 0, 15)
      log("throttle -> %d (tapped)", FORWARD_POWER)
    end
    if ev == "timer" and a == timer then
      local t = now()
      local dt = math.min(t - last, 0.5)
      last = t
      local dir = (down("faster") and 1 or 0) - (down("slower") and 1 or 0)
      if dir ~= throttleDir then
        if dir ~= 0 then stepThrottle(dir) end
        throttleDir = dir
      end
      -- Each thruster group spools toward its power while its key is held.
      local turnL = down("left") and not down("right")
      local turnR = down("right") and not down("left")
      local target = {
        forward = down("forward") and FORWARD_POWER or 0,
        back = down("back") and BACK_POWER or 0,
        left = turnL and TURN_POWER or 0,
        right = turnR and TURN_POWER or 0,
      }
      local step = THRUST_RAMP * dt
      local want = {}
      for _, g in ipairs(GROUPS) do
        want[g] = groupPower[g] + clamp(target[g] - groupPower[g], -step, step)
      end
      thrust = want.forward
      setGroups(want)
      -- turning wins over backward when both are held
      local move = nil
      if down("left") and not down("right") then move = "left"
      elseif down("right") and not down("left") then move = "right"
      elseif down("back") then move = "back" end
      applyMove(move)
      lift.updown = (down("up") and 1 or 0) - (down("down") and 1 or 0)

      screen("Fly")
      local names = {}
      for _, act in ipairs(ACTIONS) do if down(act.id) then names[#names + 1] = act.label end end
      local gp = function(g) return math.floor(groupPower[g] + 0.5) end
      out(" Keys      ", #names > 0 and { C.key, table.concat(names, ", ") } or { C.dim, "none held" })
      print("")
      -- Throttle: [-] bar [+]; tap a cell to jump to that level.
      local thr = math.floor(FORWARD_POWER + 0.5)
      local _, ty = cursor()
      ty = ty or 5
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
      term.setCursorPos(1, ty + 1)
      out(" Forward   ", meter(gp("forward"), 15, 10), string.format(" %2d", gp("forward")),
        "   Back    ", meter(gp("back"), 15, 10), string.format(" %2d", gp("back")))
      out(" Turn L    ", meter(gp("left"), 15, 10), string.format(" %2d", gp("left")),
        "   Turn R  ", meter(gp("right"), 15, 10), string.format(" %2d", gp("right")))
      print("")
      out(" Lift      ", meter(shift, 256, 11, C.head), string.format(" %3d/256  ", math.floor(shift + 0.5)),
        { C.dim, lift.status })
      if alt then
        out(" Height    ", string.format("%.1f", alt), "   ",
          { math.abs(vy) < 0.3 and C.good or C.warn, string.format("%+.1f b/s", vy) })
      end
      if #velSensors > 0 then out(" Speed     ", velText(), { C.dim, "  (sensor)" }) end
      if #relays > 0 and currentMove then
        out(" Relays    ", currentMove, { C.dim, " (" .. describe(cfg.moves[currentMove]) .. ")" })
      end
      if relayError then out({ C.bad, " Relay error: " .. relayError }) end
      print("")
      footer({ { "Q", "Menu", { char = "q" } }, { "-", "Slower", { char = "-" } }, { "+", "Faster", { char = "+" } },
        { "", "ship keeps hovering" } })
      timer = os.startTimer(0.05)
    end
  end
  lift.updown = 0
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
    for i, act in ipairs(ACTIONS) do
      out(" ", { C.key, tostring(i) }, string.format("  %-11s ", act.label), { C.head, cfg.keys[act.id] })
    end
    print("")
    hint(" Tap an action (or press 1-8) to change its key.")
    footer({ { "R", "Reset to defaults", { char = "r" } }, { "Q", "Back", { char = "q" } } })
    local ch = waitChar("12345678rq")
    if ch == "q" then return end
    if ch == "r" then
      for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = name end
      saveConfig()
    else
      local act = ACTIONS[tonumber(ch)]
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
-- that combination as turn left, turn right or backward.
local function gearshiftSetup()
  if #relays == 0 then screen("Gearshift setup") print("No Redstone Relay found.") pause() return end
  local list = {}
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do
      if #list < 9 then list[#list + 1] = { relay = r, side = side } end
    end
  end
  applyMove(nil)
  allRelaysOff()
  local on = {}
  while true do
    screen("Gearshift setup")
    hint(" Switch relay sides until the ship does what you")
    hint(" want, then save it. Easiest while hovering.")
    for i, o in ipairs(list) do
      out(" ", { C.key, tostring(i) }, string.format("  %-20s ", (#relays > 1 and (o.relay .. " ") or "") .. o.side), onOff(on[i]))
    end
    heading(" Save what's ON as:")
    out(" ", { C.key, "L" }, "  turn left   ", { C.dim, describe(cfg.moves.left) })
    out(" ", { C.key, "R" }, "  turn right  ", { C.dim, describe(cfg.moves.right) })
    out(" ", { C.key, "B" }, "  backward    ", { C.dim, describe(cfg.moves.back) })
    footer({ { "C", "All off", { char = "c" } }, { "Q", "Done", { char = "q" } } })
    if relayError then out({ C.bad, " Relay error: " .. relayError }) end
    local ch = waitChar("123456789lrbcq")
    local n = tonumber(ch)
    if n and list[n] then
      on[n] = not on[n]
      setOutput(list[n], on[n])
    elseif ch == "l" or ch == "r" or ch == "b" then
      local cur = {}
      for i, o in ipairs(list) do if on[i] then cur[#cur + 1] = { relay = o.relay, side = o.side } end end
      local id = ch == "l" and "left" or ch == "r" and "right" or "back"
      cfg.moves[id] = cur
      saveConfig()
      log("gearshift setup: saved %s = %s", id, describe(cur))
    elseif ch == "c" then
      on = {}
      allRelaysOff()
    elseif ch == "q" then
      allRelaysOff()
      outState = {}
      return
    end
  end
end

local function hoverCalibration()
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
    help = { "Backward thrusters' power." } },
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
  { name = "MANUAL_LIFT_STEP", label = "Manual lift step", step = 4, min = 0, max = 128,
    help = { "Only without a height reading: lift", "added or taken away while up/down", "is held." } },
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
  if #thrusters == 0 then screen("Thruster setup") print("No thrusters found.") pause() return end
  local page, sel = 0, 1
  local KEYROLE = { w = "forward", s = "back", a = "left", d = "right", u = "lift", o = "off" }
  while true do
    screen("Thruster setup")
    local first = page * 9
    for i = 1, 9 do
      local t = thrusters[first + i]
      if t then
        local r = roleOf(t)
        local col = r == "lift" and C.head or r == "move" and C.good or r == "unset" and C.warn or C.dim
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
    out(" ", { C.key, "U" }, " lift     ", { C.key, "O" }, " off")
    local items = { { "T", "Test-fire", { char = "t" } }, { "X", "All lift", { char = "x" } } }
    if #thrusters > 9 then
      items[#items + 1] = { "P", "", { char = "p" } }
      items[#items + 1] = { "", string.format("%d/%d", page + 1, math.ceil(#thrusters / 9)) }
      items[#items + 1] = { "N", "", { char = "n" } }
    end
    items[#items + 1] = { "Q", "Back", { char = "q" } }
    footer(items)
    local ch = waitChar("123456789wsaduotxnpq")
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
      liftSent, groupSent, thrusterSent = {}, {}, {}
      groupPower = { forward = 0, back = 0, left = 0, right = 0 }
      thrust = 0
      setShift(shift)
      return
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
      out(" Thrusters  ", { C.head, string.format("%d lift  %d fwd  %d back  %d+%d turn", #liftT, #group.forward,
        #group.back, #group.left, #group.right) })
    end
    out(" Hover      ", cfg.hover and string.format("%d/256", cfg.hover) or { C.warn, "not calibrated - tap Hover" },
      transmission and { C.dim, "   (lift transmission)" } or "")
    out(" Lift       ", meter(shift, 256, 14, C.head), " ", { C.dim, lift.status },
      alt and { C.dim, string.format("  y %.1f", alt) } or "")

    local L, R, w = 2, 27, 24
    tile(L, 8, w, "F", "Fly", "fly with typewriter")
    tile(R, 8, w, "P", "Thrusters", "jobs for each thruster")
    tile(L, 11, w, "H", "Hover", "calibrate hovering")
    tile(R, 11, w, "U", "Tuning", "power, speed, response")
    tile(L, 14, w, "K", "Keybinds", "typewriter keys")
    tile(R, 14, w, "G", "Gearshifts", "optional relay turning")
    tile(L, 17, w, "T", "Typewriter test", "see what keys arrive")
    tile(R, 17, w, "M", "Manual test", "relays, thrust, lift")
    term.setCursorPos(2, H)
    if relayError then
      fg(C.bad) write(("Relay error: " .. relayError):sub(1, W - 2)) fg(colors.white)
    end
    local ch = waitChar("ftkghupm")
    if ch == "f" then flyScreen()
    elseif ch == "t" then typewriterTest()
    elseif ch == "k" then keybinds()
    elseif ch == "g" then gearshiftSetup()
    elseif ch == "h" then hoverCalibration()
    elseif ch == "u" then tuning()
    elseif ch == "p" then thrusterSetup()
    elseif ch == "m" then manualTest() end
  end
end

-- ---------- main ----------

local args = { ... }
loadConfig()
sortThrusters()
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
    log("S %-6s keys=%s thrust=%d move=%s lift=%s %d/256 hover=%s y=%s vy=%+.2f vel=%s pos=%s",
      currentScreen or "-", #held > 0 and table.concat(held, "+") or "-", math.floor(thrust + 0.5),
      currentMove or "-", lift.mode, math.floor(shift + 0.5), lift.hover and tostring(math.floor(lift.hover + 0.5)) or "-",
      alt and string.format("%.2f", alt) or "-", vy, velText(),
      posX and string.format("%.1f,%.1f", posX, posZ) or "-")
    sleep(currentScreen == "Fly" and 0.2 or 1)
  end
end

local function ui()
  if args[1] == "fly" then flyScreen() end
  menu()
end

-- Start the log (keeping the previous run as ship.log.old).
if fs.exists(LOG_FILE) then
  if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
  fs.move(LOG_FILE, LOG_FILE .. ".old")
end
logFile = fs.open(LOG_FILE, "w")
log("Ship Pilot v%s", VERSION)
for _, name in ipairs(peripheral.getNames()) do log("peripheral %s: %s", name, tostring(peripheral.getType(name))) end
for _, v in ipairs(velSensors) do log("velocity sensor %s axis %s", v.name, tostring(v.axis)) end
for _, t in ipairs(thrusters) do log("thruster %s role %s", t.name, roleText(t)) end
log("Sable: %s  transmission start level: %d  lift mode: %s", tostring(onSable), math.floor(shift + 0.5), lift.mode)
log("config: %s", textutils.serialize(cfg):gsub("%s+", " "))
log("settings: FORWARD_POWER=%s THRUST_RAMP=%s ALT_HOLD=%s CLIMB_SPEED=%s LIFT_GAIN=%s LIFT_LEARN=%s MANUAL_LIFT_STEP=%s",
  tostring(FORWARD_POWER), tostring(THRUST_RAMP), tostring(ALT_HOLD), tostring(CLIMB_SPEED),
  tostring(LIFT_GAIN), tostring(LIFT_LEARN), tostring(MANUAL_LIFT_STEP))

pcall(mirrorToMonitor)
local ok, err = xpcall(function() parallel.waitForAny(liftLoop, ui, sampleLoop, touchLoop) end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
if logFile then logFile.close() end
-- Thrusters and turning off; the lift stays where it is so the ship doesn't drop.
allThrustOff()
applyMove(nil)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  print("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in ship.log (pastebin put ship.log).")
end
print("Thrusters and turning are off. Lift is still at " .. math.floor(shift + 0.5) .. "/256.")
