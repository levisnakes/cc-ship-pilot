-- Ship Pilot: fly a Create Aeronautics ship from a Linked Typewriter.
--
-- Starts in a menu on the computer:
--   F  fly (keys on the typewriter, default W A S D, Space, Left Shift)
--   T  typewriter test: shows the last key pressed
--   K  keybinds: change which typewriter key does what
--   G  gearshift setup: work out the turning/backward wiring
--   H  hover calibration: find the lift level that hovers
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

VERSION = "2.0.0"

-- ======================== SETTINGS ===========================
-- Keys, gearshift wiring and the hover level are set from the menus.
-- To change these, put the lines in ship_settings.lua (updates never
-- touch it), e.g.  FORWARD_POWER = 10

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

-- ---------- saved setup ----------

local cfg

local function defaultConfig()
  local r = relays[1] or "redstone_relay_0"
  return {
    keys = {},
    -- One relay, a Redstone Link on four of its sides.
    outputs = {
      { relay = r, side = "front", prop = "left" },
      { relay = r, side = "back",  prop = "left" },
      { relay = r, side = "left",  prop = "right" },
      { relay = r, side = "right", prop = "right" },
    },
    -- Which outputs are on for each move (numbers in the list above).
    moves = { left = { 2, 3 }, right = { 1, 4 }, back = { 2, 4 } },
    hover = nil,
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
end

-- ---------- outputs ----------

local outState = {}
local function setOutput(o, on)
  local key = o.relay .. ":" .. o.side
  if outState[key] == on then return end
  outState[key] = on
  pcall(peripheral.call, o.relay, "setOutput", o.side, on)
end

local function allRelaysOff()
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do setOutput({ relay = r, side = side }, false) end
  end
end

local currentMove = nil
local function applyMove(move)
  currentMove = move
  local on = {}
  if move and cfg.moves[move] then
    for _, i in ipairs(cfg.moves[move]) do on[i] = true end
  end
  for i, o in ipairs(cfg.outputs) do setOutput(o, on[i] == true) end
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
  if transmission and s ~= sentShift then
    sentShift = s
    pcall(transmission.setShiftLevel, s)
  end
end

-- ---------- typewriter keys ----------

local twHeld = {}     -- keys held on the typewriter right now
local twSeen = {}     -- code -> when the typewriter last had it held
local function pollTypewriter()
  twHeld = {}
  if not typewriter then return end
  local ok, codes = pcall(typewriter.getPressedKeyCodes)
  if ok and type(codes) == "table" then
    local t = now()
    for _, c in ipairs(codes) do twHeld[c], twSeen[c] = true, t end
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

-- mode "off": the lift is left alone (parked, or set by hand in a menu).
-- mode "fly": hover, or climb/sink while up/down is held.
local lift = { mode = "off", updown = 0, hover = nil, holdAlt = nil,
  steadySince = nil, landedSince = nil, status = "parked" }

local function holdingHeight() return ALT_HOLD and onSable and alt ~= nil end

local function liftStep(dt)
  if not transmission then return end
  if lift.mode == "off" then
    if lift.updown <= 0 then return end
    -- Take off: start from the saved hover level.
    lift.mode = "fly"
    lift.hover = math.max(shift, cfg.hover or 0)
    lift.holdAlt = nil
  end
  if holdingHeight() then
    local want = lift.updown * CLIMB_SPEED
    if lift.updown ~= 0 then
      lift.holdAlt = nil
    else
      lift.holdAlt = lift.holdAlt or alt
      want = clamp(0.5 * (lift.holdAlt - alt), -CLIMB_SPEED, CLIMB_SPEED)
    end
    -- Holding down while not moving: it's on the ground, so land.
    if lift.updown < 0 and math.abs(vy) < 0.1 then
      lift.landedSince = lift.landedSince or now()
      if now() - lift.landedSince > 1.5 then
        lift.mode, lift.status, lift.landedSince = "off", "landed", nil
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
    if lift.updown == 0 and math.abs(vy) < 0.2 then
      lift.steadySince = lift.steadySince or now()
      if now() - lift.steadySince > 5 then
        lift.steadySince = now()
        if not cfg.hover or math.abs(cfg.hover - lift.hover) > 2 then
          cfg.hover = math.floor(lift.hover + 0.5)
          saveConfig()
        end
      end
    else
      lift.steadySince = nil
    end
    lift.status = lift.updown > 0 and "climbing" or lift.updown < 0 and "descending"
      or string.format("hovering at %.1f", lift.holdAlt)
  else
    local base = cfg.hover or lift.hover or shift
    lift.hover = base
    setShift(base + lift.updown * MANUAL_LIFT_STEP)
    lift.status = lift.updown > 0 and "more lift" or lift.updown < 0 and "less lift" or "hover level"
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

local function screen(title)
  term.clear()
  term.setCursorPos(1, 1)
  print("Ship Pilot v" .. VERSION .. " - " .. title)
  print("")
end

local function waitChar(allowed)
  while true do
    local _, ch = os.pullEvent("char")
    ch = ch:lower()
    if not allowed or allowed:find(ch, 1, true) then return ch end
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
      print("Move:   " .. (currentMove or "-"))
      print(liftLine())
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

local function gearshiftSetup()
  if #relays == 0 then screen("Gearshift setup") print("No Redstone Relay found.") pause() return end
  screen("Gearshift setup")
  print("Step 1: each relay side turns on in turn.")
  print("Say which turning propeller spins.")
  print("Do this hovering or with room to turn.")
  pause("Press any key to start, Q to cancel.")
  applyMove(nil)
  allRelaysOff()
  local found = {}
  for _, r in ipairs(relays) do
    for _, side in ipairs(RELAY_SIDES) do
      local o = { relay = r, side = side }
      setOutput(o, true)
      screen("Gearshift setup")
      print(string.format("%s, side %s is ON.", r, side))
      print("")
      print("Which turning propeller is spinning?")
      print("  1 = left   2 = right   0 = neither")
      print("  Q = cancel")
      local ch = waitChar("120q")
      setOutput(o, false)
      if ch == "q" then return end
      if ch ~= "0" then
        found[#found + 1] = { relay = r, side = side, prop = ch == "1" and "left" or "right" }
      end
    end
  end
  local L, R = {}, {}
  for i, o in ipairs(found) do
    if o.prop == "left" then L[#L + 1] = i else R[#R + 1] = i end
  end
  if #L == 0 or #R == 0 then
    screen("Gearshift setup")
    print("Need at least one side for each propeller.")
    print("Nothing was changed.")
    pause()
    return
  end

  local moves = {}
  local steps = {
    { id = "left", q = "turning LEFT" },
    { id = "right", q = "turning RIGHT" },
    { id = "back", q = "moving BACKWARD" },
  }
  for _, st in ipairs(steps) do
    for _, li in ipairs(L) do
      for _, ri in ipairs(R) do
        if not moves[st.id] then
          for i, o in ipairs(found) do setOutput(o, i == li or i == ri) end
          screen("Gearshift setup")
          print("Step 2: watch the ship.")
          print("")
          print("Is it " .. st.q .. "?")
          print("  Y = yes   N = try the next one")
          print("  Q = cancel")
          local ch = waitChar("ynq")
          if ch == "q" then allRelaysOff() return end
          if ch == "y" then moves[st.id] = { li, ri } end
        end
      end
    end
    allRelaysOff()
  end
  screen("Gearshift setup")
  local missing = {}
  for _, st in ipairs(steps) do if not moves[st.id] then missing[#missing + 1] = st.q end end
  if #missing > 0 then
    print("Nothing matched: " .. table.concat(missing, ", "))
    print("Check the wiring and try again.")
    print("Nothing was changed.")
  else
    cfg.outputs, cfg.moves = found, moves
    saveConfig()
    print("Saved. Turning and backward are set up.")
  end
  pause()
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
        screen("Hover calibration")
        print(string.format("Hover level saved: %d/256", cfg.hover))
        pause()
        return
      end
      if t - started > 90 then
        screen("Hover calibration")
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
    print("M  Manual test")
    local ch = waitChar("ftkghm")
    if ch == "f" then flyScreen()
    elseif ch == "t" then typewriterTest()
    elseif ch == "k" then keybinds()
    elseif ch == "g" then gearshiftSetup()
    elseif ch == "h" then hoverCalibration()
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

local function ui()
  if args[1] == "fly" then flyScreen() end
  menu()
end

local ok, err = pcall(parallel.waitForAny, liftLoop, ui)
-- Thrusters and turning off; the lift stays where it is so the ship doesn't drop.
setThrusters(0)
applyMove(nil)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then print("Stopped: " .. tostring(err)) end
print("Thrusters and turning are off. Lift is still at " .. math.floor(shift + 0.5) .. "/256.")
