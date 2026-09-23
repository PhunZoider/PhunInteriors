# Adding rooms and vehicles

PhunInteriors is a registry. Every room it ships is registered with the same
calls described here, and a third party mod can add rooms for its own
vehicles, bind its vehicles to our rooms, or hang a room off a placed object,
without depending on us.

## Register from a vanilla event

```lua
Events.OnInitGlobalModData.Add(function()
    if not PhunInteriors then return end     -- not installed; nothing to do

    PhunInteriors.registerRoom("theirmod.busrooms", {
        label     = "Bus - Party",
        size      = {w = 4, h = 8},          -- footprint, walls included
        spawn     = {x = 1, y = 1},          -- where a tenant appears
        front     = "south",                 -- which edge faces the nose
        cab       = true,                    -- leaving by it puts you in a seat
        generator = {x = 1, y = 17, z = 0},  -- omit for a room with no power
        locations = {                        -- every place it is stamped
            [0] = {22543, 12419, 0},
            [1] = {22568, 12419, 0},
        },
    })

    PhunInteriors.registerVehicles({
        id      = "theirmod.buses",
        rooms   = {"theirmod.busrooms"},
        scripts = {"Base.87fordB700school"},
    })
end)
```

**Use `Events.OnInitGlobalModData`, not one of our events.** It always exists,
so your `.Add` line cannot fail whichever order the mods load in, and it fires
on a dedicated server as well as on clients. By the time it runs every mod's
Lua has loaded, so the `if not PhunInteriors` check is a real answer rather
than a race.

Two things that look right and are not:

- **`if PhunInteriors then ... end` at the top of your file.** It works when
  your mod loads after ours and silently does nothing when it loads first. Put
  the check inside the handler.
- **`OnGameStart`.** It never fires on a dedicated server, so your rooms would
  exist on every client and not on the server, which is where allocation and
  containment run.

Our own events, `PhunInteriorsOnRegisterRooms`, `PhunInteriorsOnRegisterVehicles`
and `PhunInteriorsOnReady`, still fire and are what our generated files use.
They only work if our `core.lua` has loaded before your file, which is why the
vanilla hook is the recommended one.

Registering late is fine. The indexes rebuild on the first read after any
registration, and a binding may name a room that registers after it.

## `registerRoom(id, def)`

A room is a **contract**: one shape, and every place on the map it is stamped.
Two designs that differ in shape, spawn, exit or power are two rooms. Decor is
not part of the contract; it is captured per stamp in game.

| Field | Required | Meaning |
|---|---|---|
| `size` | yes | `{w, h}`, the footprint **including** the south and east walls. PZ draws those walls on the squares beyond the floor, so a 2x3 floor is a 3x4 footprint. |
| `spawn` | yes | `{x, y}`, an offset from the north-west corner. Must be a square a tenant can stand on, not under furniture. |
| `locations` | yes | Every stamp, keyed by index, as `{x, y, z}` or `{x = , y = , z = }` world coordinates of the footprint's north-west corner. |
| `label` | no | Shown in the admin window. Editable later; the id is not. |
| `front` | no | `"north"`, `"south"`, `"east"` or `"west"`: the edge facing the front of the vehicle. Leaving by any edge then lands the tenant on the matching side of the vehicle. Without it they land beside the vehicle. |
| `cab` | no | `true` makes the front edge put the tenant in a free seat instead of on the ground. |
| `generator` | no | `{x, y, z}` offset of the room's generator. Omit it and the room has no power. There is deliberately no default. |
| `selfPowered` | no | `true` means the generator costs the vehicle nothing. It still needs a `generator`. |
| `reservoir` | no | `false` refuses the rain reservoir kit. On by default. |
| `baseWeight` | no | What the fitted room weighs empty, added to the vehicle. |
| `priority` | no | Lower is handed out first among rooms reachable by exactly the same vehicles. Never overrides specificity. |
| `hardenShell` | no | `true` always hardens the walls, `false` never does, omitted follows the server's option. |
| `singleUse` | no | When the last person leaves, the room is handed back and scrubbed at once. For spawn rooms and arrival halls. |
| `shared` | no | Every object bound to this room opens onto one shared space: a hub. Never reclaimed; only an admin clears it. |

`requires` no longer exists. A def carrying it still loads; the field is
ignored.

**The slot index is what a lease remembers.** Append new stamps with new
indices. Never renumber, and if you remove one, leave its index as a gap:
renumbering moves every later lease into somebody else's room.

**Re-registering an id replaces it.** Use your own namespaced id
(`yourmod.something`). Registering over one of ours to "add" stamps would
delete ours out from under live leases.

## `registerVehicles(def)`

| Field | Meaning |
|---|---|
| `rooms` | Room ids this binding reaches. |
| `scripts` | Full vehicle script names, like `Base.StepVan`. |
| `id` | Optional. Re-registering the same id replaces your binding. |
| `match` | Optional predicate, handed the vehicle. It can only add vehicles, never remove them. |

**Bindings are unioned, never overridden.** Naming `Base.StepVan` adds your
rooms to the ones our binding offers; it does not take the step van away from
us. A car mod can bind its van to one of our rooms without asking us for
anything but the room id, and a map pack can bind a vanilla van to its rooms
without asking us for anything at all.

**Allocation drains the most specialised room first**, counting how many
distinct scripts can reach each room. A room reachable only by your van is
used before a general one your van shares with twenty others, so the general
capacity is saved for vehicles with nowhere else to go. A room reachable
through `match` sorts last, since anything at all might claim it. Write
predicates tightly; we stopped using one ourselves because a name pattern was
wrong about roughly one vehicle in fourteen.

## `registerObjects(def)`

Hangs a room off a placed world object: a tent, a manhole, a phone box.

```lua
PhunInteriors.registerObjects({
    id        = "theirmod.tents",
    rooms     = {"theirmod.tentrooms"},
    items     = {"Base.TentGreen", "Base.TentBlue"},
    sprites   = {"fixtures_bathroom_01_0"},
    permanent = false,
})
```

- **`items`** are moveable item types. Right for anything a player carries
  about: one `Base.TentGreen` covers all thirty-two sprites of a green tent.
- **`sprites`** are sprite names. Right for fixtures no item stands behind.
  Any facing of the sprite matches, and so does any tile of a multi-tile
  object when you name its first tile.
- **`permanent`** makes every object the binding matches refuse pickup,
  disassembly and destruction by anybody, admins included. Use a sprite
  nothing else in the world uses.
- **`match`** works as it does for vehicles, handed the object.

A tent room pays for its power from a generator the player parks nearby. A
tent cannot be packed away while anybody is inside or anything is left in its
room.

## `registerBoarding(map)`

Where a vehicle is boarded, per script:

```lua
PhunInteriors.registerBoarding({
    ["Base.MyCamper"] = "door",           -- any seat's door
    ["Base.MyVan"]    = "SeatRearRight",  -- a named area of the vehicle
})
```

Without one, a vehicle is boarded at its `TruckBed` or `TrunkDoor` area, then
at any door. Side door campers need one, because most of them also declare a
`TruckBed` and players would be sent round the back.

## Server side calls

For mods that move players themselves. All run on the server, and all refuse
in plain English.

| Call | What it does |
|---|---|
| `PhunInteriors.enterRoom(player, roomId, opts)` | Put a player in a room with no vehicle behind it. `opts`: `share` joins an existing lease when the room is full, `exit = false` removes the way out, `returnTo = {x, y, z}` is where they come back out, `reason` is for the log. Safe to call again for somebody already inside. Returns `true, "room#index"` or `false, why`. |
| `PhunInteriors.sendTo(player, {x, y, z}, reason, release)` | Take a player out of their room to a place you choose. `release` hands the room back once the last person is out. |
| `PhunInteriors.setRoomOpen(roomId, open, {evict, scrub})` | Open or close a room. |
| `PhunInteriors.isRoomOpen(roomId)` | Whether it is taking tenants. |

## Building the map

A room is a building you draw on your own map cells. What the code expects:

- **The footprint and the floor differ.** North and west walls sit on the
  floor's own squares; south and east walls sit on the squares beyond it. The
  `size` you register is the floor plus one each way.
- **Containment is the floor, not the walls.** Stepping off the floor is
  leaving, whichever edge you cross. Put doors where you want exits.
- **The generator** must be outside the room, on an exterior square, and
  within `GeneratorTileRange` (20 by default) of every floor square. It must
  not reach the neighbouring room's floor. The shipped rooms put it 17 squares
  south, in a sealed, roofed 1x1 box so nobody can reach it or see it.
- **Paint a `NoPowerOrWater` zone** over your rooms, or they run on the mains
  until the grid shuts off. No zone may be wider or taller than 1202 squares;
  PZ silently drops bigger ones.
- **Give every stamp room a real vanilla room definition name.** The name
  picks the loot, and a name vanilla does not know spawns little or nothing.
- **Ship empty cells around your block** or fence it. Zombies spawn in cells
  no map covers and walk in.
- **Check your registry against your map** with
  `perl scripts/roomcheck.pl --mod ../YourMod`. It reads the lotpacks and reports
  any floor square no registered slot covers, and any slot whose box does not
  match its floor.

Our tiledef (`media/phuninteriors.tiles`, sheet 3050) is used by PhunSpawn and
PhunHub for their ground and fences. If you use it too, depend on this mod.
