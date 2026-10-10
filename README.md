# CC Ship Pilot

Fly a Create Aeronautics ship from a **Linked Typewriter** (Create Simulated) with ComputerCraft. The ship hovers on its own whenever you're not pressing up or down.

## Install

Run these on the ship's computer:

```
wget https://raw.githubusercontent.com/levisnakes/cc-ship-pilot/main/startup.lua startup.lua
reboot
```

If it says the file already exists, run `delete startup.lua` first. On every boot, `startup.lua` downloads the newest version as `ship.lua` and runs it.

## Controls (on the typewriter)

Right-click the typewriter to start using it, then pick **F (Fly)** on the computer.

| Default key | Does |
|---|---|
| W | forward thrusters |
| S | backward thrusters |
| A / D | turn left / right thrusters |
| Space | up |
| Left Shift | down (hold it on the ground to land and switch the lift off) |
| ↑ / ↓ arrows | throttle: forward power 0-15, one step per tap (repeats while held). W fires at this power. |

Change them in the **Keybinds** menu. The typewriter only passes on movement keys (WASD, Space, Shift) by itself; for the arrow keys, bind each to a Redstone Link frequency on the typewriter first (any spare frequency), then check them in **T (Typewriter test)**.

## Menu (on the computer)

Everything on screen can be **tapped**: click a key letter or its label on an advanced computer, or tap it on an **Advanced Monitor** connected to the computer (the screens are mirrored onto it if it's at least 51x19 characters; text scale 0.5 is used if needed).

| Key | Screen |
|---|---|
| F | Fly. Q on the computer goes back to the menu; the ship keeps hovering. |
| T | Typewriter test: shows the last key pressed, its code, and whether it came from the typewriter or the computer keyboard. |
| K | Keybinds: pick an action, then press the new key on the typewriter. The typewriter only passes on movement keys and keys bound to a link frequency. |
| G | Gearshift setup: press 1-6 to switch each relay side on or off and watch the ship. When it turns left, press L to save whatever is on; R for turn right, B for backward. Any combination works, even a single side. Best done hovering. |
| H | Hover calibration: holds a height 3 blocks above where it is and saves the lift level once it has been steady for 5 seconds. It also keeps fine-tuning that level while you fly. |
| U | Tuning: change flight settings with + and -, live, each with a short explanation (see below). |
| P | Thruster setup: pick a thruster (1-9, N/P for more pages) and switch its jobs on or off: **W** forward, **S** backward, **A** turn left, **D** turn right; or **U** lift, **O** off. A thruster can have several movement jobs, for example turn left *and* backward, and fires at the strongest one in use. X marks them all as lift; T test-fires the picked one for a second so you can see which it is. |
| M | Manual test: switch relay sides, the thrusters and the lift by hand. |

Everything set up from the menus is saved in `ship.cfg`.

## Log

Everything is written to `ship.log` on the computer: the parts it found, your saved setup, every relay switch (and any error), typewriter keys, screens, take-offs and landings, and five times a second the lift, height, speeds and the Velocity Sensor reading. The run before is kept as `ship.log.old`. To share it:

```
pastebin put ship.log
```

## Hardware

Everything connects to the computer over wired modems (right-click each modem to connect it; chat shows its name):

- **Linked Typewriter**
- **Velocity Sensor** (optional): its reading shows on the Fly screen and goes in the log.
- **Thrusters** (any Create Propulsion thruster). Give each a job in **P (Thruster setup)**: lift, forward, backward, turn left or turn right. Lift thrusters share the lift between them: each has 15 power steps, so 8 of them give 120 steps for smooth hovering. A big multiblock thruster is one peripheral; if it doesn't fire, put its modem on a different block of it.
- **Redstone Transmission** (optional, the old way): drives lift propellers instead of lift thrusters. The program switches it to incremental mode (0-256). **Remove any redstone wired to it**, or the two will fight.
- **Redstone Relay + Directional Gearshifts** (optional, the old way of turning): one relay with a Redstone Link (transmitting) on four of its sides, each on its own frequency. Matching receiving links sit against the straight and reverse sides of the two Directional Gearshifts. Run **G (Gearshift setup)** and it works out which side does what.

Hovering on its own needs the ship's height, which comes from CC: Sable (the computer has to be on the ship). Without it, the lift sits at the calibrated hover level and up/down add or take away a fixed amount.

## Tuning

Open **U (Tuning)** on the computer, ideally while the ship hovers so you can see the effect. Press 1-9 to pick a setting and + / - to change it; it's saved straight away. D puts it back to the default.

| Setting | What to do |
|---|---|
| Forward power | Throttle: thruster power while forward is held (0-15). The arrow keys change it too. |
| Backward power | Backward thrusters' power. |
| Turning power | Turning thrusters' power; lower it if the ship spins too fast. |
| Thrust spool-up | Lower for gentler starts and stops. |
| Climb speed | Blocks per second up or down. |
| Lift response | Raise it if the ship sags or reacts slowly to up/down; lower it if it bounces up and down quickly. |
| Hover learning | Lower it if the ship slowly bobs up and down; raise it if it drifts away from its height. |
| Hover level | The lift level that hovers. Hover calibration (H) sets it, and so does flying. |
| Manual lift step | Only used without a height reading (no CC: Sable). |
