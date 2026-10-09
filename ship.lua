-- Ship Pilot: fly a Create Aeronautics ship from a Linked Typewriter.
--
-- Starts in a menu on the computer:
--   F  fly (keys on the typewriter, default W A S D, Space, Left Shift)
--   T  typewriter test: shows the last key pressed
--   K  keybinds: change which typewriter key does what
--   G  gearshift setup: switch relay sides and save what turns/reverses
--   H  hover calibration: find the lift level that hovers
--   U  tuning: change flight settings with + and -
--   M  manual test: switch relay sides, thrusters and lift by hand
-- "ship fly" goes straight to flying.
--
-- Hardware, all on the wired modem network: the Linked Typewriter, the
-- forward thrusters, the Redstone Transmission driving the lift propellers,
-- and one Redstone Relay whose sides (through Redstone Links) power the two
-- Directional Gearshifts on the turning propellers.
--
-- The ship hovers on its own: whenever no up/down key is held (in the
-- menus too) it holds its height. Setup from the menus is saved in
-- ship.cfg.
--
-- Everything that happens is written to ship.log (the previous run is kept
-- as ship.log.old). To share it:  pastebin put ship.log

VERSION = "2.2.0"

-- ======================== SETTINGS ===========================
-- Change these from the Tuning menu (U) on the computer; what you set
-- there is saved in ship.cfg and overrides the values below.

FORWARD_POWER = 15      -- thruster power while forward is held (0-15)
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
}
local DEFAULT_KEYS = { forward = "w", back = "s", left = "a", right = "d", up = "space", down = "leftShift" }

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function now() return os.epoch("utc") / 1000 end

-- ---------- hardware ----------

local typewriter = peripheral.find("linked_typewriter")
local transmission = peripheral.find("redstone_transmission")
local thrusters, relays = {}, {}
for _, name in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(name)
  if THRUSTER_TYPES[t] then thrusters[#thrusters + 1] = peripheral.wrap(name) end
  if t == "redstone_relay" then relays[#relays + 1] = name end
end
table.sort(relays)

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

local thrust = 0
local sentThrust = nil
local function setThrusters(power)
  local p = math.floor(clamp(power, 0, 15) + 0.5)
  -- Spooling up/down is in the samples; log only reaching off or full.
  if p ~= sentThrust and (p == 0 or p == math.floor(FORWARD_POWER + 0.5)) then log("thrusters -> %d", p) end
  sentThrust = p
  for i, t in ipairs(thrusters) do
    local ok, err = pcall(t.setPower, p)
    if not ok then log("thruster %d setPower FAILED: %s", i, tostring(err)) end
  end
end

local shift = 0
local sentShift = nil
local function setShift(v)
  shift = clamp(v, 0, 256)
  local s = math.floor(shift + 0.5)
  if transmission and s ~= sentShift then
    sentShift = s
    local ok, err = pcall(transmission.setShiftLevel, s)
    if not ok then log("transmission setShiftLevel(%d) FAILED: %s", s, tostring(err)) end
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
  if not transmission then return end
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

local currentScreen = nil
local function screen(title)
  if title ~= currentScreen then
    currentScreen = title
    log("screen: %s", title)
  end
  term.clear()
  term.setCursorPos(1, 1)
  print("Ship Pilot v" .. VERSION .. " - " .. title)
  print("")
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
  print(msg or "Press any key.")
  os.pullEvent("char")
end

local function liftLine()
  local s = string.format("Lift: %d/256 %s", math.floor(shift + 0.5), lift.status)
  if alt then s = s .. string.format("  y=%.1f %+.1f", alt, vy) end
  return s
end

local function flyScreen()
  if not typewriter then screen("Fly") print("No Linked Typewriter found.") pause() return end
  local last, timer = now(), os.startTimer(0.05)
  while true do
    local ev, a = os.pullEvent()
    if ev == "char" and a:lower() == "q" then break end
    if ev == "timer" and a == timer then
      local t = now()
      local dt = math.min(t - last, 0.5)
      last = t
      local want = down("forward") and FORWARD_POWER or 0
      local step = THRUST_RAMP * dt
      thrust = thrust + clamp(want - thrust, -step, step)
      setThrusters(thrust)
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
      print("Keys:   " .. (#names > 0 and table.concat(names, ", ") or "-"))
      print(string.format("Thrust: %d/15 (%d thrusters)", math.floor(thrust + 0.5), #thrusters))
      print("Move:   " .. (currentMove or "-") .. (currentMove and (" (" .. describe(cfg.moves[currentMove]) .. ")") or ""))
      if relayError then print("Relay error: " .. relayError) end
      print(liftLine())
      if #velSensors > 0 then print("Speed sensor: " .. velText()) end
      print("")
      print("Press Q on the computer for the menu.")
      print("The ship keeps hovering there.")
      timer = os.startTimer(0.05)
    end
  end
  lift.updown, thrust = 0, 0
  setThrusters(0)
  applyMove(nil)
end

local function typewriterTest()
  local lastKey = nil
  while true do
    screen("Typewriter test")
    print("Press keys on the typewriter.")
    print("")
    if lastKey then
      print(string.format("Last key: %s (code %d)", keyName(lastKey.code), lastKey.code))
      print("From:     " .. lastKey.from)
      local bound = "-"
      for _, act in ipairs(ACTIONS) do
        if keys[cfg.keys[act.id]] == lastKey.code then bound = act.label end
      end
      print("Does:     " .. bound)
    else
      print("Last key: (none yet)")
    end
    local heldNames = {}
    for c in pairs(twHeld) do heldNames[#heldNames + 1] = keyName(c) end
    table.sort(heldNames)
    print("")
    print("Held now: " .. (#heldNames > 0 and table.concat(heldNames, " ") or "-"))
    print("")
    print("Q on the computer: back to the menu")
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
      print(string.format("%d  %-11s %s", i, act.label, cfg.keys[act.id]))
    end
    print("")
    print("1-6 change a key, R reset to defaults,")
    print("Q back to the menu")
    local ch = waitChar("123456rq")
    if ch == "q" then return end
    if ch == "r" then
      for id, name in pairs(DEFAULT_KEYS) do cfg.keys[id] = name end
      saveConfig()
    else
      local act = ACTIONS[tonumber(ch)]
      screen("Keybinds")
      print("Press the new key for " .. act.label)
      print("on the TYPEWRITER.")
      print("")
      print("It only passes on movement keys and")
      print("keys bound to a link frequency.")
      print("")
      print("Q on the computer to cancel")
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
            print("That was the computer keyboard;")
            print("press it on the typewriter.")
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
    print("Switch sides until the ship does what")
    print("you want, then save it. Best hovering.")
    for i, o in ipairs(list) do
      print(string.format(" %d  %-20s %s", i, (#relays > 1 and (o.relay .. " ") or "") .. o.side, on[i] and "ON" or "off"))
    end
    print("Save what's ON as:")
    print(" L  turn left:  " .. describe(cfg.moves.left))
    print(" R  turn right: " .. describe(cfg.moves.right))
    print(" B  backward:   " .. describe(cfg.moves.back))
    print(" C  all off     Q  done")
    if relayError then print("Relay error: " .. relayError) end
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
  if not transmission then screen("Hover calibration") print("No Redstone Transmission found.") pause() return end
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
      print(string.format("Holding height %.1f (now %.1f)", target, alt))
      print(string.format("Lift %d/256, vertical speed %+.2f", math.floor(shift + 0.5), vy))
      print(string.format("Steady for %.1f of 5 seconds", steady))
      print("")
      print("Q on the computer to stop")
      if steady >= 5 then
        cfg.hover = math.floor(lift.hover + 0.5)
        saveConfig()
        log("hover calibration: saved %d", cfg.hover)
        screen("Hover calibration")
        print(string.format("Hover level saved: %d/256", cfg.hover))
        pause()
        return
      end
      if t - started > 90 then
        screen("Hover calibration")
        log("hover calibration: didn't settle (alt %.2f target %.2f vy %.2f shift %d)", alt, target, vy, shift)
        print("It didn't settle in 90 seconds.")
        print("Nothing was changed.")
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
    print(string.format("Lift: %d/256", math.floor(level + 0.5)))
    print("")
    print("+ / -  change by 8     ] / [  change by 1")
    print("Enter  save this as the hover level")
    print("Q      cancel")
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
      for i, side in ipairs(RELAY_SIDES) do
        print(string.format("%d  %s side %-7s %s", i, r, side, on[side] and "ON" or "off"))
      end
    end
    print(string.format("T  forward thrusters (%d)  %s", #thrusters, thrustOn and "ON" or "off"))
    print(string.format("+/-  lift %d/256", math.floor(shift + 0.5)))
    print("Q  back (relays and thrusters off)")
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
  { name = "FORWARD_POWER", label = "Forward power", step = 1, min = 0, max = 15,
    help = { "Thruster power while forward is held." } },
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
      print(string.format("%s%d %-17s %s", i == sel and ">" or " ", i, t.label, v and tostring(v) or "-"))
    end
    print("")
    for _, line in ipairs(TUNE[sel].help) do print(line) end
    print("")
    print("1-7 pick  +/- change  D default  Q back")
    print(liftLine())
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

local function menu()
  while true do
    screen("Menu")
    print(string.format("Typewriter %s, transmission %s,", typewriter and "ok" or "MISSING", transmission and "ok" or "MISSING"))
    print(string.format("%d thrusters, %d relays%s", #thrusters, #relays, onSable and ", Sable ship" or ""))
    print("Hover level: " .. (cfg.hover and (cfg.hover .. "/256") or "not calibrated"))
    print(liftLine())
    print("")
    print("F  Fly")
    print("T  Typewriter test")
    print("K  Keybinds")
    print("G  Gearshift setup (turning/backward)")
    print("H  Hover calibration")
    print("U  Tuning")
    print("M  Manual test")
    if relayError then print("Relay error: " .. relayError) end
    local ch = waitChar("ftkghum")
    if ch == "f" then flyScreen()
    elseif ch == "t" then typewriterTest()
    elseif ch == "k" then keybinds()
    elseif ch == "g" then gearshiftSetup()
    elseif ch == "h" then hoverCalibration()
    elseif ch == "u" then tuning()
    elseif ch == "m" then manualTest() end
  end
end

-- ---------- main ----------

local args = { ... }
loadConfig()
if transmission then
  pcall(transmission.setTransmissionMode, "incremental")
  local ok, cur = pcall(transmission.getShiftLevel)
  shift = ok and type(cur) == "number" and cur or 0
  sentShift = math.floor(shift + 0.5)
  -- Already flying when the program starts (e.g. after a reboot): hover.
  if shift > 0 then lift.mode, lift.hover = "fly", shift end
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
log("Sable: %s  transmission start level: %d  lift mode: %s", tostring(onSable), math.floor(shift + 0.5), lift.mode)
log("config: %s", textutils.serialize(cfg):gsub("%s+", " "))
log("settings: FORWARD_POWER=%s THRUST_RAMP=%s ALT_HOLD=%s CLIMB_SPEED=%s LIFT_GAIN=%s LIFT_LEARN=%s MANUAL_LIFT_STEP=%s",
  tostring(FORWARD_POWER), tostring(THRUST_RAMP), tostring(ALT_HOLD), tostring(CLIMB_SPEED),
  tostring(LIFT_GAIN), tostring(LIFT_LEARN), tostring(MANUAL_LIFT_STEP))

local ok, err = xpcall(function() parallel.waitForAny(liftLoop, ui, sampleLoop) end, debug.traceback)
log("stopped: %s", ok and "ok" or tostring(err))
if logFile then logFile.close() end
-- Thrusters and turning off; the lift stays where it is so the ship doesn't drop.
setThrusters(0)
applyMove(nil)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
  print("Stopped: " .. tostring(err):match("^[^\n]*"))
  print("Details are in ship.log (pastebin put ship.log).")
end
print("Thrusters and turning are off. Lift is still at " .. math.floor(shift + 0.5) .. "/256.")
