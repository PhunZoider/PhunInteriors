# Running a server

Everything an admin can see and change, in game and from the console.

## The room window

Open it from the **admin panel**, the **debug menu** (PhunInteriors), or the
console with `PhunInteriors.roomList()`. It has three tabs.

**Rooms** lists every registered room: its label, floor size, which way out
leads where, whether it has power, how many slots are free, and which vehicles
or objects can reach it. Select one and press **Enter** to lease a slot and
stand in it. This is a real lease, so the room behaves exactly as it would for
a tenant: the leash contains you, the decor is captured, a dirty slot is
scrubbed on arrival. That is the point. A room that behaved differently with
an admin in it would be a room nobody had tested.

**Slots** lists every stamp of one room: where it is, whether it is free,
leased, occupied, waiting to be scrubbed or claimed as a safehouse, how long
since anybody was in and who. Two dropdowns narrow it by vehicle and by room.
Per slot:

- **Enter** puts you in that slot.
- **Reset** takes the slot back from whoever holds it. Everything in it is
  cleared the next time it is handed out. Refused while somebody is inside or
  while the slot is claimed as a safehouse.
- **Scrub** puts the slot back to its blueprint now. The holder keeps it; what
  was left lying about does not survive.
- **Recapture** takes the slot as it looks right now as its blueprint, so
  every later scrub restores to this. Stand in it first.

**Bindings** lists which vehicle scripts, items and sprites reach which rooms.

## Editing rooms and bindings

The window can change the registry while the server runs. Edit a room's label,
shape, spawn square, exits, generator and flags; add, move or delete its
stamps; create, edit or delete bindings. Changes apply the moment you make
them, so you can stand in the room you just changed.

**Nothing autosaves.** Press **Save** to write your changes to
`PhunInteriors.json` in the server's `Zomboid/Lua` folder, next to the other
Phun mods' override files. Close the window with unsaved changes and it asks
first; a restart loses anything unsaved. **Discard** throws away everything
since the last save.

What the file holds is only what you changed. A room you never touched keeps
following the mod, including when a later version changes it.

Each row carries a stripe: shipped (as the mod registered it), overridden (the
mod's, with your changes on top) or new (yours alone).

Some things worth knowing:

- **A room id can never change**, because it is what a lease remembers.
- **Deleting a slot leaves a gap in the numbering.** That is deliberate:
  renumbering would move every later lease into somebody else's room. A
  leased slot cannot be deleted.
- **Deleting a binding the mod registered** lasts until the next restart, when
  the mod registers it again.
- **Moving a stamp in the editor does not move anything on the map.** It
  changes where the mod thinks the room is. Use it to correct the registry,
  not to relocate rooms.

## Opening and closing rooms

A closed room hands out no new leases and turns away tenants who already hold
one. Leaving is always allowed. Admins can still enter a closed room to fix
it. Closed stays closed across a restart.

```lua
PhunInteriors.admin("close", {room = "phun.room.Van", evict = true, scrub = true})
PhunInteriors.admin("open",  {room = "phun.room.Van"})
```

`evict` puts everybody inside out. `scrub` resets every slot nobody is in.

## Console commands

From the client console as an admin, or as `/interiors <action>` in chat when
PhunServer2 is installed.

| Command | What it does |
|---|---|
| `admin("rooms", {filter = ...})` | Every room with its slot counts and what reaches it. The filter matches id, label, script or item, so `{filter = "mail"}` finds the mail van's room. |
| `admin("list")` | Every lease: which vehicle, which slot, how long idle, who used it last, where the vehicle is and whether that position is live. |
| `admin("bindings")` | Every binding and what it reaches. |
| `admin("enter", {room = ..., index = ...})` | Put yourself in a room. Index is optional. |
| `admin("release", {room = ..., index = ...})` | Reset a slot, as the button does. Also takes `{vehicleId = ...}`. |
| `admin("free", {vehicleId = ...})` | Release whatever a vehicle holds. Refused, like `release`, while somebody is inside or the slot is claimed as a safehouse. |
| `admin("scrub", {room = ..., index = ...})` | Scrub one slot now. With no arguments, works through up to ten waiting slots. |
| `admin("remanifest", {room = ..., index = ...})` | Recapture a slot's blueprint. |
| `admin("manifests")` | How big every captured blueprint is. |
| `admin("evict", {username = ...})` | Put a player out of their room. |
| `admin("open" / "close", {room = ..., evict, scrub})` | See above. |
| `admin("power", {room = ..., index = ...})` | Grid state, the room's generator and the battery ledger. |
| `admin("weight")` | What each leased vehicle is being charged. |
| `admin("reload")` | Re-read the sandbox options now. |
| `admin("save")` / `admin("revertAll")` | Save the editor's changes, or throw them away and re-read the file. |
| `admin("reclaim", {room = ...})` | Take the lease a full pool would take next. Room is optional. |
| `admin("age", {vehicleId = ..., days = ...})` | Make a lease look idle for that many days. |
| `admin("shove", {radius = ...})` | Run the exit zombie shove where you stand. |

All are called as `PhunInteriors.admin(...)`. They run on the server, and the result is printed to the console log rather than returned.

## Testing the rare paths

Two mechanics only happen when a server is busy, so there are commands to
force them.

**Reclaiming.** Enter a room through a vehicle, leave, then:

```lua
PhunInteriors.admin("age", {vehicleId = "...", days = 99})
PhunInteriors.admin("reclaim")
```

Enter again through the same vehicle: you get a fresh room and a message. Do
not go into the room between `age` and `reclaim`; going in renews the lease,
which is the mechanic working, and the test quietly stops meaning anything.

**The exit shove.** Spawn a horde on yourself and run `admin("shove")`.

## Safehouses

Players can claim a room as a safehouse with vanilla's own tools. A claimed
room is never reclaimed, scrubbed or reset, and it turns away anybody the
claim does not allow, admins included unless their role can enter any
safehouse. To free one, remove the claim the vanilla way first.

## Other mods

- **PhunServer2**, if installed, adds the `/interiors` chat command. Nothing
  else depends on it.
- **PhunSpawn** and **PhunHub** register rooms of their own through this mod
  and ship map cells beside ours.
- **Other map mods** must not use cells 87,46 to 91,48 or 89,49 to 91,49.
  Two maps claiming the same cell means one silently loses it.
