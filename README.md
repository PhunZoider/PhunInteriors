# PhunInteriors

Instanced vehicle interiors for Project Zomboid **B42**, in single player and
multiplayer.

Park an interior off-grid, lease it to a vehicle, and put the player inside.
The usual RV interior mods do this too. This one differs in what happens
afterwards.

## What it does differently

| | Common RV mods | PhunInteriors |
|---|---|---|
| Room slots | Assigned once, never freed. Pool exhausts silently | Leased with a `lastSeen` stamp, reclaimed on demand and scrubbed |
| Exit position | Cached on a one minute timer | Read live off the vehicle, with a tracked position for when it is unloaded |
| Interior loot | Weightless | Adds a configurable share of its weight to the vehicle |
| Containment | Indestructible walls | A bounding box test, so the walls can be destructible later |
| Leaving | Right-click a context menu | Walk out of the door. Containment takes you home |
| Vehicle list | A 682 line literal | A registry other mods extend, bound by game script name |
| SP and MP | Two implementations that drift | One code path, dispatched through `Core.dispatch` |

## Containment

Containment is a property of the space, not the tiles. While anyone is inside,
one bounding box test per occupant every 250ms covers roof access, neighbouring
instances, wall breaches and teleport exploits. Because containment does not
depend on the walls, the walls can be destructible later.

**There is exactly one way out.** Walking out of a doorway, a hole in the wall
and a tripped leash all call the same thing, which puts the player back at the
vehicle. There is no separate breach handler and there are no exit tiles —
collapsing these was deliberate, and it means the door has to actually open.

A room states which of its edges faces the holder's nose (`front`). The leash
reports which edge was crossed, and the pair resolves to `front`, `rear`,
`left` or `right` — so **which side you leave by decides where you come out**,
rather than where you got in. A room whose `front` edge sets `cab = true` puts
you in the first free seat instead of on the ground.

Nothing in the containment code knows a vehicle part name. A room says which
way its holder points; everything else is arithmetic.

## Rooms are leased, not assigned

Every assignment carries `lastSeen`. A lease **never expires on a clock** — it
is reclaimed when somebody else needs it. Allocation spends every free and
quarantined slot the vehicle could reach first, and only then takes the lease
unused the longest, and only if it has gone unused for `RoomProtectedDays` with
nobody inside. Set that option to its maximum and no room is ever taken; set it
to 0 and any unused room is fair game once the pool is full.

Released slots go to quarantine and are **reissued and then scrubbed**, not
scrubbed and then reissued. A scrub needs the chunk loaded, and nothing loads
the chunk of a room nobody has been near — so the scrub rides the first arrival
instead. The invariant is "never *used* dirty".

## Scrub

A scrub reconciles: keep what the blueprint expects and the square already has,
remove the extras, create only what is genuinely missing. It is not a chunk
revert — no Lua call reloads a chunk from its lotpack, and PZ persists modified
chunks into the save.

Reconciling rather than rebuilding is not a style choice. The engine picks an
object's class from its sprite when the map loads, and `IsoObject.new` always
returns a plain `IsoObject` — so a *rebuilt* light switch is a picture of a
light switch. Anything that does have to be recreated goes through a
constructor that reads the sprite type.

**Blueprints are captured, not authored, and captured per slot** the first time
that slot is leased, when it is pristine by definition. There is no golden
slot. A map author can decorate each stamp differently and each is restored to
what they actually built there. Resolution order is the slot's own capture, then
a shipped room-level blueprint if one was registered, then any sibling slot.

## Power and water

The room runs off the vehicle battery through a real `IsoGenerator`, because
`square:haveElectricity()` reads no flag — it is only ever
`chunk:isGeneratorPoweringSquare`. The generator's position is fixed data on the
room, and a room that declares none simply has no power. The two halves are
never loaded together, so a ledger on the lease carries the debt between them;
the tank is a buffer and the **battery** is the limiting resource.

A rain reservoir is barrels on the roof, placed from a craftable kit, covering
the floor rather than one per square — vanilla plumbing searches the 3x3 above a
fixture, so one barrel per third square reaches everything.

## For mod authors

Register from a **vanilla** event, not one of ours:

```lua
Events.OnInitGlobalModData.Add(function()
    if not PhunInteriors then return end     -- definitive by now

    PhunInteriors.registerRoom("theirmod.busrooms", {
        label     = "Bus",
        size      = {w = 4, h = 8},          -- footprint, walls included
        spawn     = {x = 1, y = 1},
        front     = "south",                 -- which edge faces the nose
        cab       = true,                    -- that edge puts you in a seat
        generator = {x = 1, y = 17, z = 0},  -- omit for a room with no power
        locations = {                        -- every place it is stamped
            [0] = {22543, 12419, 0},
            [1] = {22568, 12419, 0},
        },
    })

    PhunInteriors.registerVehicles({
        id      = "theirmod.buses",
        rooms   = {"theirmod.busrooms"},
        scripts = {"Base.87fordB700school"}, -- a vanilla script name, so no
    })                                       -- id of ours has to be looked up
end)
```

**Why `Events.OnInitGlobalModData` and not `PhunInteriorsOnRegisterRooms`.**
`Events` is a plain table with no metatable, so a key exists only once
`AddEvent` has been called for it. If your file loads before ours, `.Add` on our
event throws and firing later cannot rescue a listener that was never attached.
`OnInitGlobalModData` always exists, fires everywhere including a dedicated
server, and by the time it runs all Lua has loaded — so the nil check is
decisive rather than a race. Our own two events (`OnRegisterRooms`,
`OnRegisterVehicles`, then `OnReady`) still work and are what the generated
files use; the vanilla hook is the one nobody can get wrong.

`if PhunInteriors then ... end` at **file scope** is the thing that does not
work: it passes standalone and fails silently when your file loads first. The
nil check belongs inside the handler, not around it.

Other properties worth knowing:

- **Ids are namespaced** `author.name`. Re-registering your own room replaces
  it, so "adding" rooms to somebody else's id would delete theirs out from
  under live leases. Register your own and bind to it.
- **A location index is the identity a lease persists.** Appending is safe;
  renumbering re-points every lease after the change at somebody else's room. A
  deleted location must leave a gap.
- **Bindings are unioned, never overridden.** Naming `Base.StepVan` adds your
  rooms to the ones an existing binding already offers rather than taking the
  vehicle over.
- **Allocation drains the most specialised room first**, where specificity is
  how many distinct scripts can reach it. That stops general-purpose capacity
  being spent on vehicles that had an alternative. `priority` breaks ties below
  specificity, and room id below that so a save allocates the same way twice.
- **`match` is a predicate that only ever adds** to a binding's script list. A
  room reached through one sorts last, because anything at all might claim it.
- **A room says nothing about what may carry it.** Which holder may lease which
  room is the binding's answer. There is no `requires`.

Non-vehicle holders work the same way — `registerObjects` binds by moveable
**item type**, which is what vanilla's own pickup path keys on:

```lua
PhunInteriors.registerObjects({
    id    = "theirmod.tents",
    rooms = {"theirmod.tentrooms"},
    items = {"Base.TentGreen", "Base.TentBlue"},
})
```

## Status

Every mechanic is proven in game in single player and on a **real dedicated
server** — enter and exit, containment, seat and door restore, blueprint
capture, scrub, the lease lifecycle, weight, towing, the destroy guards and the
fire dousing. Multiplayer was proven against a dedicated server rather than a
listen host, which matters: only a dedicated server unloads the vehicle's chunk
the way the exit design assumes.

Newer work that has **not** run in game yet: the reshaped exit contract
(`front`/`cab`), power binding, the in-game registry editor, world-object
holders, reclaim-on-demand and the rain reservoir. See `CLAUDE.md` → "Known
gaps" for what to watch in each.

The map ships 20 cells carrying 83 rooms across 990 slots. `Docs/roomcheck.pl`
is the only thing that checks the registry against the lotpacks and should be
run whenever the map moves.

## Requires

Nothing. There are no hard dependencies and `mod.info` carries no `require`
line. PhunServer2 is used for chat commands when present and is never required.

## Admin

The room list is the main tool — admin panel, debug menu, or
`PhunInteriors.roomList()`. Three tabs: Rooms, Slots, Bindings. It shows every
room, its contract, what can reach it, and per slot how long since anybody was
inside. Select a room and press Enter to be standing in it. Edits are kept as a
sparse patch in `PhunInteriors.json` beside the other Phun override files, and
nothing autosaves.

From the console, or as `/interiors <action>` when PhunServer2 is loaded:

```
PhunInteriors.admin("list")
PhunInteriors.admin("rooms")
PhunInteriors.admin("free",       {vehicleId = "..."})
PhunInteriors.admin("release",    {room = "phun.room.Bus_3x9", index = 9})
PhunInteriors.admin("scrub",      {room = "phun.room.Bus_3x9", index = 3})
PhunInteriors.admin("manifests")
PhunInteriors.admin("power",      {room = "phun.room.Bus_3x9", index = 3})
PhunInteriors.admin("evict",      {username = "..."})
PhunInteriors.admin("reclaim")
```

## Development

`bash Tests/run.sh` parses every Lua file with LuaJIT, runs three static checks
and then the specs — 552 checks. It is not a mock of the game: anything needing
an `IsoGridSquare` is tested in game or not at all.

`Docs/` holds the tooling that reads the jar and the map: `methods.pl` and
`body.pl` for what an API call actually does, `tiles.pl`, `rooms.pl` and
`zombies.pl` for what a cell actually contains, `roomcheck.pl` and
`fencecheck.pl` for whether the registry and the fence match what ships, and
`gendefaults.pl` to regenerate `defaults.lua` from the three CSVs.
