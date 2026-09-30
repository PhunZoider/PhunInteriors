# Giving your vehicles a room

If you make vehicle mods, you can give your vehicles an interior with about
ten lines of Lua and no map work at all. PhunInteriors ships 83 furnished
rooms; you just say which of them your vehicles open onto.

Your mod does **not** need to depend on PhunInteriors. If a player does not
have it installed, your code does nothing.

## The whole thing

Put this in any Lua file of yours under `media/lua/shared/` (so it runs on
the server and on clients):

```lua
Events.OnInitGlobalModData.Add(function()
    if not PhunInteriors then return end     -- not installed: nothing to do

    PhunInteriors.registerVehicles({
        id      = "yourmod.vans",
        scripts = {"Base.YourVan", "Base.YourVanPolice"},
        rooms   = {"phun.room.Van_Mechanic", "phun.room.Van"},
    })
end)
```

That is it. Load the game, right click your van and choose **Go inside**.

## Picking a room

[Supported vehicles](vehicles.md) lists every room, its floor size and what
already uses it. A room's id is its name with `phun.room.` in front and the
spaces and dashes turned into single underscores:

| Name | Id |
|---|---|
| Van | `phun.room.Van` |
| Van - Mechanic | `phun.room.Van_Mechanic` |
| Step Van - Mail | `phun.room.Step_Van_Mail` |
| Bus - School | `phun.room.Bus_School` |
| Camper - Small | `phun.room.Camper_Small` |
| Semi Trailer - Warehouse | `phun.room.Semi_Trailer_Warehouse` |

In game, the admin room window (`PhunInteriors.roomList()`) shows every id,
and so does `PhunInteriors.admin("rooms")` in the console.

Pick one that suits the vehicle's size and job. A few are there for mods to
claim and have nothing bound to them yet: **`phun.room.Bus`**,
**`phun.room.RV_Spare_1`** and **`phun.room.RV_Spare_2`**.

**List more than one room** to give your vehicle somewhere to go when its
favourite is full. You do not have to order them: the room reachable by the
fewest vehicles is always handed out first, so a specialised room fills before
the general one listed beside it.

## Getting the script names right

Each entry is a vehicle script's **full name**, module included:
`Base.YourVan`, not `YourVan`. It is `module` plus `vehicle` from your
`media/scripts/vehicles/*.txt`:

```
module Base
{
    vehicle YourVan
    {
```

Case does not matter. A name that is wrong simply never matches, with no
error, so if your van has no way in, this is the first thing to check.

## You never take a vehicle away from anybody

Bindings add up. If PhunInteriors, or another mod, already gives
`Base.StepVan` a room and you bind it to another one, the step van gets
**both**. So covering a vanilla vehicle is safe, and so is covering one another
mod already covers.

Use your own `id`. Registering again under the same id replaces your binding,
which is how you update it.

## Side doors

A player boards at the back of a vehicle by default: its `TruckBed` or
`TrunkDoor` area, then any door. That is wrong for a camper or a bus whose
door is in the side, and most of those still declare a `TruckBed`. Tell us
where the door is:

```lua
    PhunInteriors.registerBoarding({
        ["Base.YourCamper"] = "door",           -- any seat's door
        ["Base.YourBus"]    = "SeatRearRight",  -- one named area of the vehicle
    })
```

Put it in the same handler as `registerVehicles`.

## Which side players come out

Each room knows which of its walls faces the front of the vehicle. Walking out
the back wall lands the player behind the vehicle, the front wall in front of
it (or in a free seat, for rooms with a cab), and so on. For the rear to work
your vehicle should declare a `TruckBed` or `TrunkDoor` area, which nearly
every vehicle does. Without one the player comes out at the nearest door,
which is still a fine answer.

## Checking it worked

- **In game:** open `PhunInteriors.roomList()`, go to the **Bindings** tab,
  and look for your id. The **Rooms** tab shows your scripts beside each room
  they reach.
- **In the console:** `PhunInteriors.admin("rooms", {filter = "YourVan"})`
  prints every room your van can reach. Results go to the console log.
- **No "Go inside" option on your van?** The script name did not match.
  Print the real one while sitting in the driver's seat:

  ```lua
  print(getPlayer():getVehicle():getScript():getFullName())
  ```

## Two mistakes that look right

- **`if PhunInteriors then ... end` at the top of your file.** It works when
  your mod happens to load after ours and silently does nothing when it loads
  first. Keep the check inside the `OnInitGlobalModData` handler, as above.
- **`Events.OnGameStart`.** It never fires on a dedicated server, so your
  vehicles would have rooms on every client and not on the server, where the
  rooms are actually handed out.

## Wanting a room of your own?

If none of ours fits, you can ship your own room design on your own map cells.
See [Adding rooms from your map](map-authors.md). The full API, every field
and every option, is in [Adding rooms and vehicles](modding.md).

A server admin can also map any vehicle to any room from inside the game, with
no mod at all: [Mapping a vehicle or an object to a room](remapping.md).
