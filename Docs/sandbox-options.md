# Sandbox options

Every option sits on the **PhunInteriors** page of the sandbox settings.
Defaults are what a new server gets. Changes are picked up within ten minutes
of game time; an admin can force it at once with
`PhunInteriors.admin("reload")`.

Every constraint can be turned off. If one is taking the fun out of it on your
server, turn it off.

## Getting in

| Option | Default | Range | What it does |
|---|---|---|---|
| Entry Time | 1 | 0 to 120 | Seconds it takes to get inside. Walking, running or aiming cancels it. 0 is instant. |
| Enter At The Door | on | | You walk to the back of a van or the door of a caravan to get in, rather than going in from anywhere beside it. |
| Block Entry When Chased | on | | You cannot get in while a zombie is close, so the interior is not an escape hatch mid chase. Checked when the action finishes, not when it starts. |
| Entry Block Radius | 10 | 1 to 30 | How close, in squares, a zombie has to be to stop you. |

## Coming out

| Option | Default | Range | What it does |
|---|---|---|---|
| Zombies Accumulate | on | | Zombies near the vehicle build up while you are inside, so you come out to a bigger crowd than you left. Off lets you wait out the night for free. |
| Accumulation Rate | 2 | 0 to 50 | Extra zombies per hour spent inside. |
| Exit Clears Zombies | 6 | 0 to 30 | Squares of ground cleared around you as you land. Anything inside is pushed to the edge of the ring, as far as walls allow. Nothing is removed. 0 turns it off. |
| Breaching Ejects You | on | | Leaving the room any way other than the door (a broken wall, say) puts you back at the vehicle. Off moves you back inside instead. |

## Keeping rooms

| Option | Default | Range | What it does |
|---|---|---|---|
| Days A Room Is Kept | 14 | 0 to 99999999 | Rooms are never taken while any are free. Once every room a vehicle could have is in use, it is given the one unused the longest, if it has gone unused for at least this many days. Whatever was in it is cleared. 0 lets any unused room be reused as soon as they are all taken. The maximum means a room is never reused: vehicles are simply refused once the last one is gone. A room claimed as a safehouse is never reused, whatever this says. |

There is no option to keep a reclaimed room's contents. There was one, and it
never worked: the items were cleared either way. It has been removed rather
than left claiming otherwise.

## Weight and power

| Option | Default | Range | What it does |
|---|---|---|---|
| Interior Weight Factor | 50 | 0 to 1000 | Percentage of the weight of everything in the room added to the vehicle. Affects handling, acceleration and braking, not fuel use. 0 makes interior loot weightless. A van weighs around two tonnes, so values over 100 are mostly useful to feel the effect at all. |
| Interior runs off the vehicle battery | on | | The room's generator is fuelled from the vehicle's battery. A flat battery means a dark room. Off leaves interior power alone. |
| Interior power drain (%) | 100 | 0 to 1000 | How much battery charge the room costs, as a percentage of what its generator burns. 100 is one full battery per full tank. 0 means the lights are free. |

Generator range is vanilla's own `GeneratorTileRange`. Leave it at 20 or
above: every shipped room relies on a generator 17 squares away.

## Walls

| Option | Default | Range | What it does |
|---|---|---|---|
| Unbreakable Outer Walls | on | | Room walls and light switches refuse to be destroyed, and fires in a room are put out. Individual rooms can override this either way in the room editor. Containment does not depend on it. |

## Admin and debugging

| Option | Default | Range | What it does |
|---|---|---|---|
| Noclip Frees Admins | on | | An admin with noclip turned on is ignored by containment, so they can pass through rooms without being put out. Turning noclip off puts them back under the normal rules. |
| Debug | off | | Verbose logging for leases, scrubs and containment. Useful when reporting a problem; noisy otherwise. |

## Vanilla settings that matter

- **Zombie distribution must not be Uniform.** Uniform places zombies
  everywhere regardless of map density, including between the rooms. All
  vanilla presets use Urban Focused.
- **Allow exterior generators** needs to stay on for tents: a tent's generator
  sits outdoors.
