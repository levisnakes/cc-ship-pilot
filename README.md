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
| S | backward (both turning propellers push back) |
| A / D | turn left / right |
| Space | up |
| Left Shift | down (hold it on the ground to land and switch the lift off) |

Change them in the **Keybinds** menu.

## Menu (on the computer)

| Key | Screen |
|---|---|
| F | Fly. Q on the computer goes back to the menu; the ship keeps hovering. |
| T | Typewriter test: shows the last key pressed, its code, and whether it came from the typewriter or the computer keyboard. |
| K | Keybinds: pick an action, then press the new key on the typewriter. The typewriter only passes on movement keys and keys bound to a link frequency. |
| G | Gearshift setup: turns each relay side on in turn and asks which turning propeller spins, then tries each combination and asks whether the ship is turning left, turning right or going backward. Do it hovering or with room to turn. |
| H | Hover calibration: holds a height 3 blocks above where it is and saves the lift level once it has been steady for 5 seconds. It also keeps fine-tuning that level while you fly. |
| M | Manual test: switch relay sides, the thrusters and the lift by hand. |

Everything set up from the menus is saved in `ship.cfg`.

## Hardware

Everything connects to the computer over wired modems (right-click each modem to connect it; chat shows its name):

- **Linked Typewriter**
- **Thrusters** (any Create Propulsion thruster): every one on the network pushes forward.
- **Redstone Transmission** driving the four lift propellers. The program switches it to incremental mode (0-256, 16 times finer than redstone). **Remove any redstone wired to it**, or the two will fight.
- **One Redstone Relay** with a Redstone Link (transmitting) on four of its sides, each on its own frequency. Matching receiving links sit against the straight and reverse sides of the two Directional Gearshifts. Run **G (Gearshift setup)** and it works out which side does what.

Hovering on its own needs the ship's height, which comes from CC: Sable (the computer has to be on the ship). Without it, the lift sits at the calibrated hover level and up/down add or take away a fixed amount.

## Settings

Tuning values are at the top of `ship.lua`: `FORWARD_POWER`, `THRUST_RAMP`, `ALT_HOLD`, `CLIMB_SPEED`, `LIFT_GAIN`, `LIFT_LEARN`, `MANUAL_LIFT_STEP`. To change one, put the line in `ship_settings.lua` (updates never touch it), for example `CLIMB_SPEED = 6`.
