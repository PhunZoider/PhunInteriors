# Mapping a vehicle or an object to a room

Any vehicle, and any placed object, can open onto any room. You can do it from
inside the game while the server runs, with no code, no restart and no second
mod. This page walks through it.

Want a modded van to get the mechanic's workshop? Want a portable toilet that
is secretly the door to a hub? Same five steps.

You need to be an admin. In single player, turn on debug mode or use a
save where you are admin.

## 1. Find the name of the thing

A binding names what reaches a room by its game name, so first find that name.

**A vehicle** is named by its **script**, in full, with its module:
`Base.StepVan`, not `StepVan`. Upper and lower case do not matter. Sit in the
driver's seat and paste this into the debug console:

```lua
print(getPlayer():getVehicle():getScript():getFullName())
```

Or open the vehicle mod's files: `media/scripts/vehicles/*.txt` holds
`module Base { vehicle MyVan {`, which is `Base.MyVan`.

**A carried object**, like a tent, is best named by its **moveable item**:
`Base.TentGreen`. One item name covers every tile and every facing of it. Pick
it up, then list what you are carrying:

```lua
local items = getPlayer():getInventory():getItems()
for i = 0, items:size() - 1 do print(items:get(i):getFullType()) end
```

**A fixture**, like a toilet or a phone box, is named by its **sprite**. Stand
next to it and run this, which prints every sprite on the squares around you:

```lua
local sq = getPlayer():getSquare()
for dx = -1, 1 do for dy = -1, 1 do
  local s = getCell():getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
  if s then
    for i = 0, s:getObjects():size() - 1 do
      local o = s:getObjects():get(i)
      if o:getSprite() then print(dx, dy, o:getSprite():getName()) end
    end
  end
end end
```

Any facing of a sprite matches, so you only need one. For a fixture that spans
several tiles, name its first tile.

## 2. Open the room window

From the **admin panel**, the **debug menu** (PhunInteriors), or the console:

```lua
PhunInteriors.roomList()
```

The **Rooms** tab lists every room with its floor size and what already
reaches it. Pick the room you want now, and note its id (for example
`phun.room.Van_Mechanic`). [Supported vehicles](vehicles.md) shows every
room's contents if you want to choose from a list first.

## 3. Make the binding

Go to the **Bindings** tab and press **New**.

| Field | What to put |
|---|---|
| **Binding id** | A name of your own with a dot in it, like `myserver.vans`. Using an id that already exists replaces that binding. |
| **Holder kind** | `vehicle` for a vehicle, `object` for anything placed in the world. |
| **Rooms it reaches** | Press **Add** and pick from the menu. Pick more than one if you want a fallback for when the first is full. |
| **Vehicle scripts** | (vehicles) Press **Add** and type the script name from step 1. |
| **Moveable items** | (objects) The item name from step 1. |
| **Sprites** | (objects) The sprite name from step 1. |
| **Permanent** | (objects) Makes every matching object impossible to pick up, take apart or destroy, for anybody. Only tick it for a sprite nothing else in the world uses. |

Press **Apply**. The binding is live immediately.

## 4. Try it

Walk to the vehicle or object, right click it and choose **Go inside**. Look
around, then walk back out.

If there is no **Go inside**, check the name in step 1 first. A script name missing
its `Base.` matches nothing, and so does a sprite from the wrong tile.

## 5. Save

Press **Save** at the bottom of the window. Your changes are written to
`PhunInteriors.json` in the server's `Zomboid/Lua` folder, and come back on
every restart.

**Nothing saves on its own.** Until you press Save, a restart loses the
change. The window asks before closing if anything is unsaved.

## Moving a vehicle to a different room

Bindings add up. A new binding for `Base.VanMail` gives the mail van your room
**as well as** the one it already had. That is deliberate: it means two mods
covering the same vehicle never take anything from each other.

To move a vehicle rather than add to it:

1. On the **Bindings** tab, find the binding that already names it. The
   **Reached by** column lists the scripts.
2. Press **Edit**, select the script in **Vehicle scripts**, remove it, and
   press **Apply**.
3. Make your new binding as above, then **Save**.

Editing a binding the mod shipped is kept across restarts. **Deleting** one is
not: the mod registers it again on the next boot. Edit, do not delete.

## Things worth knowing

- **Which room a vehicle gets.** When a vehicle can reach several rooms, the
  one reachable by the fewest vehicles is handed out first, so a room made for
  your van fills before the general van room it shares with forty others.
  **Priority** on the room form breaks ties.
- **Players keep what they had.** Re-pointing a binding does not move anybody
  already holding a room. It decides where the next one goes.
- **A room with no power stays dark** whatever reaches it. The Rooms tab's
  Power column says which rooms have a generator.
- **A tent or other object pays for its lights** from a generator parked
  nearby. With none, the room is dark.
- **Making a brand new room** is a map job, not an editor one: see
  [Adding rooms from your map](map-authors.md).

The full editor, including rooms, slots and console commands, is on
[Running a server](admin.md).
