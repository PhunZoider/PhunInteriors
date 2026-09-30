# Adding rooms from your map

If you make maps, you can add interiors of your own: draw a room once, stamp
it as many times as you like on your own cells, and say which vehicles or
objects open onto it. Players get your room exactly as they get ours, with
the walking in and out, containment, power, weight and cleanup all handled
for you.

Your map does **not** need to depend on PhunInteriors. Without it, your cells
are just buildings nobody can reach.

## What you are making

- **A room design**: one shape, one spawn square, one door arrangement. Draw
  it in BuildingEd like any building.
- **Stamps** of it on your own cells. Twenty stamps of one design means twenty
  players (or twenty vehicles) can each have their own copy.
- **A few lines of Lua** that tell PhunInteriors where the stamps are and what
  opens onto them.

Decor is yours. Each stamp's furniture, wallpaper and floor are recorded the
first time it is used, and put back that way when the room is recycled, so
the stamps do not all have to look the same.

## 1. Pick your cells

Use cells well away from the playable world, as ours are. Do not use any of
these:

| Cells | Taken by |
|---|---|
| 87,46 to 91,48 | PhunInteriors |
| 89,49 to 91,49 | PhunInteriors |
| 87,49 | PhunTaxi |
| 88,49 | PhunRooms |

Two maps shipping the same cell means one of them silently loses it.

Put an empty ring of cells around your block, or fence it. Zombies spawn in
cells that no map covers and wander in.

## 2. Draw the room

A few rules the code depends on:

- **Floor and footprint are different.** PZ puts the north and west walls on
  the floor's own squares and the south and east walls on the squares beyond
  it. So a 2x3 floor has a 3x4 **footprint**, and the footprint is what you
  register.
- **Walking off the floor is leaving.** Put a working door wherever you want a
  way out. A room with four solid walls traps its tenant.
- **Name the room with a real vanilla room definition** (`mechanic`,
  `bookstore`, `grocery`...). The name picks the loot. A name vanilla does not
  know spawns little or nothing.
- **Leave the spawn square clear.** It is where a tenant appears, so it must
  not be under a shelf or a fridge.
- **Stamps must not overlap**, and nothing else should sit inside a stamp's
  footprint.

## 3. Give it power (optional)

A room with no generator has no power, which is a perfectly good room. For
lights and appliances, place one generator square per stamp that is:

- **outside** the room, on an **exterior** square,
- within **20 squares** (the default `GeneratorTileRange`) of every floor
  square,
- **not** within 20 squares of a neighbouring stamp's floor.

The mod puts a real generator there and runs it off the vehicle's battery.
Ours sit 17 squares south of each room in a sealed 1x1 box with a black lid,
so nobody can reach them or see them.

Also paint a **`NoPowerOrWater`** zone over your block, or your rooms run on
the mains until the grid shuts off. No single zone may be wider or taller than
1202 squares; PZ silently drops bigger ones, so use several.

## 4. Read the coordinates off your feet

You do not need to work out coordinates by hand. Load your map in **single
player** as admin and use the authoring tool from the debug console. Results
print to the console log.

```lua
PhunInteriors.author("begin", {id = "yourmap.garage", label = "Garage"})
PhunInteriors.author("corner")   -- stand on the north-west corner of the first stamp
PhunInteriors.author("corner")   -- then on the opposite corner
PhunInteriors.author("spawn")    -- stand where tenants should appear
PhunInteriors.author("cab")      -- optional: stand at the wall that leads to the cab
PhunInteriors.author("power")    -- optional: stand on the generator square
PhunInteriors.author("at")       -- stand in each further stamp and call this
PhunInteriors.author("scripts", {scripts = "Base.Van, Base.StepVan"})
PhunInteriors.author("status")   -- what is set so far
PhunInteriors.author("emit")
```

For an evenly spaced row, `author("strip", {count = 9, pitchX = 25})` places
ten stamps 25 squares apart in one go instead of walking to each one.

`emit` writes `PhunInteriors_yourmap_garage.lua` to your `Zomboid/Lua` folder.
Copy the numbers out of it into the handler in the next step, rather than
shipping that file as it is: it hooks our own events, which only works if our
mod happens to load before yours.

## 5. Register it

Put this in a Lua file of your own under `media/lua/shared/`:

```lua
Events.OnInitGlobalModData.Add(function()
    if not PhunInteriors then return end     -- not installed: nothing to do

    PhunInteriors.registerRoom("yourmap.garage", {
        label     = "Van - Garage",
        size      = {w = 4, h = 6},          -- footprint, walls included
        spawn     = {x = 1, y = 1},          -- offset from the north-west corner
        front     = "north",                 -- the wall facing the vehicle's nose
        generator = {x = 1, y = 17, z = 0},  -- omit for no power
        locations = {                        -- north-west corner of each stamp
            [0] = {30015, 12005, 0},
            [1] = {30040, 12005, 0},
            [2] = {30065, 12005, 0},
        },
    })

    PhunInteriors.registerVehicles({
        id      = "yourmap.garage.vans",
        rooms   = {"yourmap.garage"},
        scripts = {"Base.Van", "Base.StepVan"},
    })
end)
```

**Always use your own id** with your mod's name in front. Registering under
one of our ids replaces our room.

**Never renumber `locations`.** The number is what a player's lease
remembers, so renumbering moves people into each other's rooms. Add new stamps
at the end. If you remove one, leave its number out and leave the gap.

### Which way out goes where

`front` says which wall of your room faces the front of the vehicle. Walking
out any wall then lands the player on the matching side: out the `front` wall
in front of the vehicle, out the opposite wall behind it, and so on. Leave it
out and players land beside the vehicle whichever way they leave.

Add `cab = true` and leaving by the front wall puts the player in a free seat
instead. `author("cab")` sets both; for a front with no cab, add `front` by
hand.

### Binding vanilla vehicles is free

`registerVehicles` names vanilla (or any mod's) vehicle scripts, so you need
nobody's permission and no id of ours. Bindings add up: naming `Base.StepVan`
gives step vans your rooms **as well as** ours, and it takes nothing away from
anybody. A room reachable by fewer vehicles is handed out first, so a room
only your vehicles can reach fills before the general ones.

### A room behind an object

Rooms do not need a vehicle. Use `registerObjects` instead of (or as well as)
`registerVehicles` to put your room behind a tent, a manhole or a door:

```lua
    PhunInteriors.registerObjects({
        id      = "yourmap.bunker.hatch",
        rooms   = {"yourmap.bunker"},
        sprites = {"yourmap_tiles_01_0"},
    })
```

Add `shared = true` to the room to make every such object open onto one
common space, like a hub.

## 6. Check it

- **In game:** open `PhunInteriors.roomList()`, find your room on the
  **Rooms** tab, and press **Enter** to stand in it. Walk out each door. Try
  the **Slots** tab to visit every stamp.
- **Against the map:** if you have a checkout of the
  [PhunInteriors repository](https://github.com/PhunZoider/PhunInteriors) and
  Perl, run this from its root:

  ```bash
  perl scripts/roomcheck.pl --mod ../YourMap
  ```

  It reads your lotpacks and reports any floor square no stamp covers, and any
  stamp whose box does not line up with its floor. A stamp one square out
  looks, in game, exactly like the mod being broken.

## Things to know

- **Our tiles.** You are welcome to draw with our tile sheet
  (`media/phuninteriors.tiles`), including the black ground and fence, as
  PhunTaxi and PhunRooms do. If you do, depend on PhunInteriors, because the
  tiles ship with it.
- **Room size.** Weight is what stops a room being free storage, so a very
  large room on a light vehicle makes a very heavy van.
- **Nothing to ship for decor.** There is no blueprint file to export. Each
  stamp is recorded as you built it, the first time somebody uses it.

The full list of room fields, including single use rooms, hubs, unbreakable
walls and priority, is in [Adding rooms and vehicles](modding.md).
