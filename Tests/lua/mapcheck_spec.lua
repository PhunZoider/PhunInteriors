-- MapCheck: refusing rooms the world's map has no room for.
--
-- The two failure directions both matter. Saying yes to a missing slot leases
-- it and teleports somebody into woods; saying no to a present one, or on a
-- probe that merely failed, refuses rooms that work.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end
local MapCheck = require "PhunInteriors/mapcheck"
local Slots = require "PhunInteriors/slots"

local report = stubs.reporter()
local check = report.check
local function where(a)
    return a and (a.room .. "#" .. a.index) or "refused"
end

-- The map has a room at these slot origins (x of the floor's north-west
-- corner) and nowhere else. asked counts calls, to prove an answer is kept.
local present = {}
local asked = 0
local function mapWith(xs)
    present = {}
    for _, x in ipairs(xs) do
        present[x] = true
    end
    function getWorld()
        return {
            getMetaGrid = function()
                return {
                    countRoomsIntersecting = function(_, x, y, w, h)
                        asked = asked + 1
                        return present[x] and 1 or 0
                    end
                }
            end
        }
    end
end

local function vehicle(scriptName)
    return {
        getScript = function()
            return {
                getFullName = function()
                    return scriptName
                end,
                getName = function()
                    return scriptName
                end
            }
        end
    }
end

Core.registerRoom("m.room", {
    size = {w = 3, h = 4},
    locations = {[0] = {0, 0, 0}, [1] = {100, 0, 0}, [2] = {200, 0, 0}}
})
Core.registerRoom("m.gone", {
    size = {w = 3, h = 4},
    locations = {[0] = {0, 500, 0}}
})
Core.registerVehicles({id = "m.v", rooms = {"m.room"}, scripts = {"Base.M"}})
Core.registerVehicles({id = "m.g", rooms = {"m.gone"}, scripts = {"Base.G"}})
local van, goneVan = vehicle("Base.M"), vehicle("Base.G")

-- A probe the engine would not answer is "present", and is not remembered.
function getWorld()
    return {
        getMetaGrid = function()
            return {}
        end
    }
end
check("a grid without the call answers present", MapCheck.slotOnMap("m.room", 0), true)
mapWith({100, 200})
check("and that guess was not kept", MapCheck.slotOnMap("m.room", 0), false)
check("a slot the map has is present", MapCheck.slotOnMap("m.room", 1), true)
local before = asked
MapCheck.slotOnMap("m.room", 1)
check("and the answer is remembered", asked, before)
check("an unknown slot is not refused here", MapCheck.slotOnMap("m.room", 9), true)
check("a room with one stamp present is on the map", MapCheck.roomOnMap("m.room"), true)
check("a room with none is not", MapCheck.roomOnMap("m.gone"), false)

-- Allocation passes over the missing stamp rather than leasing it.
check("the missing slot 0 is skipped", where(Slots.acquire("a1", van)), "m.room#1")
check("the next present one is taken", where(Slots.acquire("a2", van)), "m.room#2")
check("then it is full, not missing", select(2, Slots.acquire("a3", van)), "IGUI_PhunInteriors_NoFreeRoom")
check("a holder whose every room is missing hears so", select(2, Slots.acquire("g1", goneVan)),
    "IGUI_PhunInteriors_RoomNotInWorld")

-- A stale lease in a missing slot is never reclaimed, however old.
Slots.store().assignments["old"] = {room = "m.room", index = 0, lastSeen = -99999}
Slots.store().occupied["m.room"]["0"] = "old"
check("a lease on a missing slot is not reclaimed", (Slots.oldestReclaimable({["m.room"] = 1})), nil)

-- Its holder is refused, and keeps the lease: the map may come back.
check("its own holder is refused", select(2, Slots.acquire("old", van)), "IGUI_PhunInteriors_RoomNotInWorld")
check("and still holds it", where(Slots.find("old")), "m.room#0")

-- The admin route refuses a named missing slot in plain English.
local none, why = Slots.acquireIn("admin:x", "m.gone", 0)
check("acquireIn refuses a named missing slot", none, nil)
check("and says why", why ~= nil and why:find("map") ~= nil, true)
none, why = Slots.acquireIn("admin:x", "m.gone", nil)
check("and an unnamed one in a room with none", why ~= nil and why:find("map") ~= nil, true)

-- The survey, and who is told at login.
local survey = MapCheck.survey()
check("survey counts every slot", survey.slots, 4)
check("and the missing ones", survey.missing, 2)
check("by cell", survey.cells["0,0"] ~= nil and survey.cells["0,1"] ~= nil, true)

local told = {}
Core.isLocal = false
function sendServerCommand(player, module, command, args)
    told[player.name] = args.text
end
local function player(name, level)
    return {
        name = name,
        getAccessLevel = function()
            return level
        end
    }
end

MapCheck.report()
MapCheck.alert(player("pat", "None"))
MapCheck.alert(player("ada", "Admin"))
check("a partial gap is not told to a player", told.pat, nil)
check("it is told to an admin", told.ada, "IGUI_PhunInteriors_MapMissingSome")

MapCheck.reset()
mapWith({})
told = {}
MapCheck.alert(player("pat", "None"))
check("nothing on the map is told to everybody", told.pat, "IGUI_PhunInteriors_MapMissingAll")

MapCheck.reset()
mapWith({0, 100, 200})
told = {}
MapCheck.alert(player("ada", "Admin"))
check("a complete map tells nobody", told.ada, nil)

os.exit(report.finish("mapcheck") == 0 and 0 or 1)
