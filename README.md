# PhunInteriors

Instanced vehicle interiors for Project Zomboid B42, in single player and multiplayer.

Park an interior off-grid, lease it to a vehicle, and put the player inside. The
usual RV interior mods do this too. This one differs in what happens afterwards.

## What it does differently

| | Common RV mods | PhunInteriors |
|---|---|---|
| Room slots | Assigned once, never freed. Pool exhausts silently | Leased with a `lastSeen` stamp, reclaimed and scrubbed |
| Exit position | Cached on a one minute timer | Resolved live from the vehicle |
| Interior loot | Weightless | Adds a configurable share of its weight to the vehicle |
| Containment | Indestructible walls | A bounds check, so walls can be destructible later |
| Leaving | Right-click a context menu | Walk onto the exit tile |
| Vehicle list | A 682 line literal | A registry other mods can extend |

## Containment

Containment is a property of the space, not the tiles. While a player is inside,
one bounding box test per tick-batch covers roof access, neighbouring instances,
wall breaches and teleport exploits.

Because B42 has no Lua hook on door opening, the exit is positional too. That
makes the exit test and the containment test the same test with different
outcomes, so the door, a hole in the wall, and a tripped leash all resolve to
one operation: put the player back at the vehicle.

## Reset

Rooms expire on a lease and are rebuilt from a manifest. This is a scrub, not a
chunk revert: no Lua call reloads a chunk from its lotpack, and PZ persists
modified chunks into the save. Since we author every room, rebuilding from a
manifest is equivalent in practice.

The manifest is not hand authored. Slot 0 of every room set is a golden slot
that is never leased; it is scanned once and cached. It regenerates itself when
the map behind a room set changes.

## For mod authors

```lua
Events[PhunInteriors.events.OnReady].Add(function()
    PhunInteriors.registerRoomSet("yourmod.bus", {
        origin = {x = 30000, y = 15000, z = 0},
        pitch  = {x = 60, y = 0},
        count  = 32,
        size   = {w = 4, h = 8},
        spawn  = {x = 1, y = 1},
        exits  = {{x = 1, y = 0}},
        power  = {x = 0, y = 0, z = 1},
    })

    PhunInteriors.registerVehicleClass("yourmod.bus", {
        roomSet = "yourmod.bus",
        scripts = {"Base.YourBus"},
        match   = function(vehicle) return false end,
        requires = {trunk = true},
    })
end)
```

Ids are namespaced `author.name`. A vehicle script belongs to exactly one class;
later registrations win and the override is logged rather than applied silently.
Server admins can bind extra scripts to an existing class from sandbox options
without any code.

## Status

v1 covers the lifecycle: registry, leasing, transit, containment, scrub, weight
and the balance levers. Power binding to vehicle battery and fuel, the water
barrel, and the siege system are v2.

**The stock room set coordinates are borrowed off-grid space so v1 could be
built without map authoring on the critical path. They must be replaced with a
purpose-built map before release.** Only `origin` and `count` change; that is
the point of the room set being data.

## Requires

Nothing. There are no hard dependencies. PhunServer2 is used for chat commands
when present, but is never required.

## Admin

```
/interiors list
/interiors free <vehicleId>
/interiors scrub [roomSet index]
/interiors evict <username>
/interiors remanifest <roomSet>
```
