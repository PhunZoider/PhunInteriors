local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/overrides"
local Core = PhunInteriors
local json = require "PhunInteriors/json"

local logged = {}
Core.logLn = function(text) table.insert(logged, text) end
Core.debugLn = function() end

local report = stubs.reporter()
local check = report.check

-- ---------------------------------------------------------------------------
-- The admin editor's override layer.
--
-- Every check here exists because the alternative behaviour is silent. A patch
-- that fails to apply, a revert that reverts to the patched value, a locations
-- edit that renumbers the slots after it -- none of those throws, and each one
-- either loses an admin's work or re-points a lease at somebody else's room.
-- ---------------------------------------------------------------------------

local function shippedRoom()
    Core.registerRoom("t.ship", {
        label = "Shipped",
        size = {w = 3, h = 4},
        spawn = {x = 1, y = 1},
        front = "north",
        cab = true,
        generator = {x = 0, y = 17, z = 0},
        baseWeight = 20,
        locations = {
            [0] = {1000, 1000, 0},
            [1] = {1025, 1000, 0},
            [2] = {1050, 1000, 0}
        }
    })
    return Core.rooms["t.ship"]
end

---------------------------------------------------------------------------
-- 1. The snapshot
---------------------------------------------------------------------------

shippedRoom()
check("room registered", Core.rooms["t.ship"] ~= nil, true)
check("definition snapshotted", Core.roomDefs["t.ship"] ~= nil, true)
check("snapshot keeps the author's front", Core.roomDefs["t.ship"].front, "north")
check("state starts shipped", Core.roomOverrideState("t.ship"), "shipped")

-- The snapshot must be a DEEP copy of the caller's table, and the nesting is
-- the half that matters. A shallow one shares `spawn` and every `locations`
-- entry with whatever the author passed -- and defaults.lua builds its
-- location tables in a loop and reuses the row -- so the thing revert restores
-- from tracks later edits. Revert then appears to work and changes nothing.
--
-- Deliberately not tested by mutating Core.rooms: registerRoom builds `spawn`
-- and every slot fresh, so the built room never shares with the def whatever
-- the copy does, and a check written that way passes against a shallow copy.
local liveDef = {
    size = {w = 2, h = 2},
    spawn = {x = 1, y = 1},
    locations = {[0] = {1, 1, 0}}
}
Core.registerRoom("t.share", liveDef)
liveDef.spawn.x = 42
liveDef.locations[0][1] = 999
check("snapshot does not follow the caller's nested table", Core.roomDefs["t.share"].spawn.x, 1)
check("nor the caller's locations", Core.roomDefs["t.share"].locations[0][1], 1)

-- And the merge hands out a copy too, or the first caller to touch what it
-- returned would edit the shipped definition in place.
local merged = Core.mergedRoomDef("t.share")
merged.spawn.x = 77
merged.locations[0][1] = 777
check("merge does not hand out the snapshot", Core.roomDefs["t.share"].spawn.x, 1)
check("nor its locations", Core.roomDefs["t.share"].locations[0][1], 1)

shippedRoom()

-- A definition that fails to register must not be recorded as shipped state,
-- or the editor offers a revert to something that never existed.
Core.registerRoom("t.bad", {size = {w = 2, h = 2}, locations = {}})
check("a failed registration leaves no room", Core.rooms["t.bad"], nil)
check("a failed registration leaves no snapshot", Core.roomDefs["t.bad"], nil)

---------------------------------------------------------------------------
-- 2. A scalar patch
---------------------------------------------------------------------------

check("set front", Core.setRoomOverride("t.ship", {front = "south"}), true)
check("front applied", Core.rooms["t.ship"].front, "south")
check("state is now overridden", Core.roomOverrideState("t.ship"), "overridden")
check("untouched field survives", Core.rooms["t.ship"].cab, true)
check("untouched locations survive", #Core.rooms["t.ship"].indices, 3)
check("snapshot still says north", Core.roomDefs["t.ship"].front, "north")

check("revert", Core.setRoomOverride("t.ship", nil), true)
check("front is back", Core.rooms["t.ship"].front, "north")
check("state is shipped again", Core.roomOverrideState("t.ship"), "shipped")

-- A patch identical to the shipped value leaves no entry. Without this the
-- file fills with rooms that read as customised and are not.
Core.setRoomOverride("t.ship", {front = "north", cab = true})
check("a no-op patch is not stored", Core.overrides.rooms["t.ship"], nil)
check("a no-op patch leaves the room shipped", Core.roomOverrideState("t.ship"), "shipped")

-- ...and a patch that changes one of two fields stores only the one.
Core.setRoomOverride("t.ship", {front = "east", cab = true})
check("only the changed field is stored", Core.overrides.rooms["t.ship"].front, "east")
check("the matching field is dropped", Core.overrides.rooms["t.ship"].cab, nil)
Core.setRoomOverride("t.ship", nil)

---------------------------------------------------------------------------
-- 3. Clearing a field, which JSON null cannot express
---------------------------------------------------------------------------

check("clear the generator", Core.setRoomOverride("t.ship", {clear = {generator = true}}), true)
check("generator is gone", Core.rooms["t.ship"].generator, nil)
check("slotPower reads it as no power", Core.slotPower(Core.rooms["t.ship"], 0), nil)
check("revert brings the generator back",
    Core.setRoomOverride("t.ship", nil) and Core.rooms["t.ship"].generator.y, 17)

-- Clearing something the shipped room never had is not an override.
Core.setRoomOverride("t.noclear", nil)
Core.registerRoom("t.plain", {size = {w = 2, h = 2}, locations = {[0] = {1, 1, 0}}})
Core.setRoomOverride("t.plain", {clear = {generator = true}})
check("clearing an absent field stores nothing", Core.overrides.rooms["t.plain"], nil)

---------------------------------------------------------------------------
-- 4. Locations -- the one that re-points leases when it is wrong
---------------------------------------------------------------------------

-- Moving one stamp must not disturb the others, and must not renumber.
Core.setRoomOverride("t.ship", {locations = {[1] = {7000, 7000, 0}}})
check("moved slot moved", Core.slotOrigin(Core.rooms["t.ship"], 1).x, 7000)
check("slot 0 stayed", Core.slotOrigin(Core.rooms["t.ship"], 0).x, 1000)
check("slot 2 stayed", Core.slotOrigin(Core.rooms["t.ship"], 2).x, 1050)
check("count unchanged", #Core.rooms["t.ship"].indices, 3)

-- The derived fields must follow. Writing locations straight onto the built
-- room would leave slots/indices/count describing the old set, and every
-- geometry helper reads those.
check("indices are re-derived", Core.rooms["t.ship"].indices[2], 1)
check("slots table is re-derived", Core.rooms["t.ship"].slots[1].x, 7000)

-- A tombstone deletes and leaves a GAP. Closing the gap up would renumber
-- every slot after it and re-point every lease beyond the change.
Core.setRoomOverride("t.ship", {locations = {[1] = false}})
check("tombstoned slot is gone", Core.slotOrigin(Core.rooms["t.ship"], 1), nil)
check("two slots left", #Core.rooms["t.ship"].indices, 2)
check("slot 2 kept its index", Core.rooms["t.ship"].indices[2], 2)
check("slot 2 kept its position", Core.slotOrigin(Core.rooms["t.ship"], 2).x, 1050)

-- Appending is safe and is how an admin adds a stamp.
Core.setRoomOverride("t.ship", {locations = {[1] = false, [9] = {8000, 8000, 0}}})
check("appended slot exists", Core.slotOrigin(Core.rooms["t.ship"], 9).x, 8000)
check("appended past the gap", #Core.rooms["t.ship"].indices, 3)
check("indices stay sorted", Core.rooms["t.ship"].indices[3], 9)

Core.setRoomOverride("t.ship", nil)
check("revert restores the deleted slot", Core.slotOrigin(Core.rooms["t.ship"], 1).x, 1025)
check("revert removes the added slot", Core.slotOrigin(Core.rooms["t.ship"], 9), nil)

---------------------------------------------------------------------------
-- 5. Reading a patch off disk
---------------------------------------------------------------------------

local patch, problems = Core.readRoomPatch("t.ship", {
    front = "west",
    cab = false,
    baseWeight = 45,
    locations = {["4"] = {2000, 2000, 0}, ["1"] = false},
    clear = {"generator"}
})
check("no complaints", #problems, 0)
check("edge read", patch.front, "west")
check("number read", patch.baseWeight, 45)
check("string slot key became a number", patch.locations[4][1], 2000)
check("tombstone survived the read", patch.locations[1], false)
check("clear list became a set", patch.clear.generator, true)

-- Bad values are dropped one at a time and named, never taken as truth. A
-- whole patch refused for one typo loses every other customisation in it.
local partial, why = Core.readRoomPatch("t.ship", {
    front = "up",
    cab = "yes",
    baseWeight = 12,
    spelt_wrong = 1,
    locations = {["x"] = {1, 2, 3}}
})
check("the good field survived", partial.baseWeight, 12)
check("a bad edge is dropped", partial.front, nil)
check("a non-boolean is dropped", partial.cab, nil)
check("an unknown field is dropped", partial.spelt_wrong, nil)
check("a bad slot key is dropped", partial.locations, nil)
check("every one was reported", #why, 4)

---------------------------------------------------------------------------
-- 6. The document round trip
---------------------------------------------------------------------------

Core.setRoomOverride("t.ship", {front = "south", locations = {[1] = false, [7] = {3000, 3000, 0}}})
local doc = Core.overrideDocument()
check("document names the room", doc.rooms["t.ship"].front, "south")
check("slot keys are strings on the way out", doc.rooms["t.ship"].locations["7"][1], 3000)
check("tombstone survives encoding", doc.rooms["t.ship"].locations["1"], false)

local text = json.encodePretty(doc)
check("document encodes", type(text), "string")
local decoded = json.decode(text)
check("document decodes", decoded.rooms["t.ship"].front, "south")

-- Install the decoded document over a fresh registration, which is the boot
-- path: register from lua, then put the file back on.
Core.overrides.rooms = {}
shippedRoom()
check("fresh registration is shipped", Core.roomOverrideState("t.ship"), "shipped")
local complaints = Core.installOverrides(decoded)
check("installed cleanly", #complaints, 0)
check("front came back", Core.rooms["t.ship"].front, "south")
check("tombstone came back", Core.slotOrigin(Core.rooms["t.ship"], 1), nil)
check("added slot came back", Core.slotOrigin(Core.rooms["t.ship"], 7).x, 3000)
check("state is overridden", Core.roomOverrideState("t.ship"), "overridden")

---------------------------------------------------------------------------
-- 7. A room that exists only in the file
---------------------------------------------------------------------------

Core.overrides.rooms = {}
local made = Core.installOverrides({
    rooms = {
        ["t.new"] = {
            label = "Made by an admin",
            size = {w = 2, h = 3},
            spawn = {x = 0, y = 1},
            locations = {["0"] = {5000, 5000, 0}}
        }
    }
})
check("a whole room in the file registers", Core.rooms["t.new"] ~= nil, true)
check("it reads as new", Core.roomOverrideState("t.new"), "new")
check("its slot is placed", Core.slotOrigin(Core.rooms["t.new"], 0).x, 5000)
check("no complaints about it", #made, 0)

-- Reverting a file-born room deletes it: there is nothing to fall back to.
Core.setRoomOverride("t.new", nil)
check("reverting a new room removes it", Core.rooms["t.new"], nil)

-- A patch for a room nobody registered and which is not a whole room is
-- refused rather than registering a room with no size.
Core.overrides.rooms = {}
local orphan = Core.installOverrides({rooms = {["t.ghost"] = {front = "south"}}})
check("an orphan patch does not register", Core.rooms["t.ghost"], nil)
check("an orphan patch is reported", #orphan, 1)

---------------------------------------------------------------------------
-- 8. Bindings
---------------------------------------------------------------------------

Core.overrides.rooms = {}
Core.overrides.bindings = {}
shippedRoom()
check("binding stored", Core.setBindingOverride("t.bind", {
    scripts = {"Base.TestVan"},
    rooms = {"t.ship"}
}), true)
check("binding registered", Core.bindings["t.bind"] ~= nil, true)

local function vehicle(scriptName)
    return {
        getScript = function()
            return {
                getFullName = function() return scriptName end,
                getName = function() return scriptName end
            }
        end
    }
end
-- Room IDS, not room tables. Reading `.id` off one of these is nil and looks
-- exactly like a binding that did not resolve.
local reach = Core.roomsForVehicle(vehicle("Base.TestVan"))
check("the binding reaches the room", reach[1], "t.ship")

-- A binding made by registerObjects must not be reachable by a vehicle. The
-- kind is read off the definition rather than guessed from which list is
-- filled, because a matcher-only binding fills neither.
Core.setBindingOverride("t.objbind", {
    kind = "object",
    items = {"Base.TentGreen"},
    rooms = {"t.ship"}
})
local stillOne = Core.roomsForVehicle(vehicle("Base.TestVan"))
check("an object binding does not reach a vehicle", #stillOne, 1)

check("binding dropped", Core.setBindingOverride("t.bind", nil), true)
check("dropped binding is gone", Core.bindings["t.bind"], nil)
check("and no longer reaches", #Core.roomsForVehicle(vehicle("Base.TestVan")), 0)

---------------------------------------------------------------------------
-- 9. A room that registers AFTER the file was loaded
---------------------------------------------------------------------------

-- Third parties are told to register from Events.OnInitGlobalModData, which
-- can land after our boot sequence has already read the file. A room that
-- turned up late must still pick its patch up, or it is the one room in the
-- set the admin's edits silently did not reach.
Core.overrides.rooms = {}
Core.roomDefs["t.late"] = nil
Core.rooms["t.late"] = nil

Core.installOverrides({rooms = {["t.late"] = {front = "west", cab = true}}})
check("a patch for an unregistered room is refused for now", Core.rooms["t.late"], nil)
-- ...but it is kept, so the registration that arrives later can use it.
check("the patch is kept", Core.overrides.rooms["t.late"] ~= nil, true)

Core.registerRoom("t.late", {
    size = {w = 3, h = 3},
    spawn = {x = 1, y = 1},
    front = "north",
    locations = {[0] = {6000, 6000, 0}}
})
check("the late room exists", Core.rooms["t.late"] ~= nil, true)
check("and the patch was applied to it", Core.rooms["t.late"].front, "west")
check("its own fields survived", Core.slotOrigin(Core.rooms["t.late"], 0).x, 6000)
check("it reads as overridden", Core.roomOverrideState("t.late"), "overridden")
check("and it can still be reverted", Core.setRoomOverride("t.late", nil)
    and Core.rooms["t.late"].front, "north")

report.finish("overrides")
