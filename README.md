# CC Ship Pilot

Fly a Create Aeronautics ship from a **Linked Typewriter** (Create Simulated) with ComputerCraft.

| Key | Does |
|---|---|
| W | forward thrusters |
| S | backward (both turning propellers push back) |
| A / D | turn left / right (turning propellers push opposite ways) |
| Space | up |
| Left Shift | down |

On a Sable ship (CC: Sable installed) it holds its height when you let go of Space/Shift, and learns how much lift that takes. Ctrl+T stops it: thrusters and turning go off, and the lift stays where it is so the ship doesn't drop.

## Install

Run these on the ship's computer:

```
wget https://raw.githubusercontent.com/levisnakes/cc-ship-pilot/main/startup.lua startup.lua
reboot
```

If it says the file already exists, run `delete startup.lua` first. On every boot, `startup.lua` downloads the newest version as `ship.lua` and runs it.

## Hardware

Everything connects to the computer over wired modems (right-click each modem to connect it; chat shows its name):

- **Linked Typewriter**: right-click it to start using it, then fly with the keys above.
- **Thrusters** (any Create Propulsion thruster): every one on the network is a forward thruster.
- **Redstone Transmission** driving the lift propellers. The program switches it to incremental mode (0-256). **Remove any redstone wired to it**, or the two will fight.
- **Two Redstone Relays** for the two Directional Gearshifts on the turning propellers. Each gearshift needs one relay side on its straight side and one on its reverse side.

## Setup

1. Run `startup test` (or `ship test`). Press 1-4 on the computer's keyboard to switch each relay output, and watch what each turning propeller does. T toggles the thrusters, + and - change the lift.
2. Put what you found into `ship_settings.lua` (it's never overwritten by updates), for example:

```lua
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
MOVES = {
  turnLeft  = { left = "reverse",  right = "straight" },
  turnRight = { left = "straight", right = "reverse" },
  back      = { left = "reverse",  right = "reverse" },
}
```

If it turns the wrong way or goes forward when it should go back, swap `straight` and `reverse` in MOVES.

Other settings (top of `ship.lua`, override them in `ship_settings.lua`): `KEYS`, `FORWARD_POWER`, `THRUST_RAMP`, `ALT_HOLD`, `CLIMB_SPEED`, `LIFT_GAIN`, `LIFT_LEARN`, `MANUAL_LIFT_RATE`.
