local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end
local Doors = require "PhunInteriors/doors"

local report = stubs.reporter()
local check = report.check

-- Which doors count as a way out is pure geometry and is tested here. Whether
-- ToggleDoorActual really closes one, and whether clients see it, belongs in
-- the game; the fake door below only records that it was asked.

-- A 3x4 footprint at 1000,1000: floor x 1000..1001, y 1000..1002, with the
-- south wall row at y 1003 and the east wall column at x 1002.
Core.registerRoom("r.box", {
    size = {w = 3, h = 4},
    locations = {[0] = {1000, 1000, 0}}
})
local room = Core.rooms["r.box"]
local floor = Core.slotFloor(room, 0)

check("a north door on the floor's first row leads out", Doors.isExterior(floor, 1000, 1000, true), true)
check("a north door on the south wall row leads out", Doors.isExterior(floor, 1001, 1003, true), true)
check("a north door between two floor rows is internal", Doors.isExterior(floor, 1000, 1001, true), false)
check("a west door on the floor's first column leads out", Doors.isExterior(floor, 1000, 1001, false), true)
check("a west door on the east wall column leads out", Doors.isExterior(floor, 1002, 1001, false), true)
check("a west door between two floor columns is internal", Doors.isExterior(floor, 1001, 1001, false), false)
check("a north door in the east wall column touches no floor", Doors.isExterior(floor, 1002, 1003, true), false)

-- A world holding three doors, all open: the north door, an internal one and
-- a south door. Toggling closes a door and counts the call.
local function door(north)
    local d = {open = true, north = north, toggles = 0}
    function d:IsOpen() return self.open end
    function d:getNorth() return self.north end
    function d:ToggleDoorActual(character)
        self.toggles = self.toggles + 1
        self.by = character
        self.open = not self.open
    end
    return d
end
local northDoor, innerDoor, southDoor = door(true), door(true), door(true)
local world = {
    ["1001,1000"] = {northDoor},
    ["1000,1001"] = {innerDoor},
    ["1001,1003"] = {southDoor, {}}
}
function instanceof(object, class)
    return class == "IsoDoor" and object.ToggleDoorActual ~= nil
end
function getCell()
    return {
        getGridSquare = function(_, x, y, z)
            local objects = z == 0 and world[x .. "," .. y]
            if not objects then
                return nil
            end
            return {
                getObjects = function()
                    return {
                        size = function() return #objects end,
                        get = function(_, i) return objects[i + 1] end
                    }
                end
            }
        end
    }
end

local function player(name)
    return {getUsername = function() return name end}
end
local alice, bob = player("alice"), player("bob")

Core.occupants = {
    alice = {room = "r.box", index = 0, vehicleId = "van-1"},
    bob = {room = "r.box", index = 0, vehicleId = "van-1"}
}
check("nothing is closed while somebody else is inside", Doors.closeBehind(alice, Core.occupants.alice), 0)
check("so the north door is still open", northDoor:IsOpen(), true)

Core.occupants.bob = {room = "r.box", index = 0, vehicleId = "van-2"}
check("somebody in a different room does not count", Doors.closeBehind(alice, Core.occupants.alice), 2)
check("the north door is shut", northDoor:IsOpen(), false)
check("the south door is shut", southDoor:IsOpen(), false)
check("the internal door is left open", innerDoor:IsOpen(), true)
check("closed as the arriving tenant", northDoor.by, alice)

check("a second pass touches nothing", Doors.closeBehind(alice, Core.occupants.alice), 0)
check("so nothing was toggled twice", northDoor.toggles + southDoor.toggles, 2)

-- A door that throws is logged and skipped, not fatal to the others.
northDoor.open, southDoor.open = true, true
function northDoor:ToggleDoorActual() error("boom") end
check("one bad door does not stop the rest", Doors.closeExterior("r.box", 0, alice), 1)
check("and the rest still close", southDoor:IsOpen(), false)

check("an unknown room closes nothing", Doors.closeExterior("r.nope", 0, alice), 0)

os.exit(report.finish("doors") == 0 and 0 or 1)
