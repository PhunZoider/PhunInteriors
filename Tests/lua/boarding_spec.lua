-- Where a vehicle is boarded: which point resolves for which vehicle, and who
-- counts as standing at it.
--
-- What this CANNOT see is the walk there (ISPathFindAction is client UI and
-- engine pathing) or whether a real script's area and seat offsets land where
-- the fakes put them. Those belong in game. What it can see is the resolution
-- order, which is the part that silently sends somebody round the wrong side.

local root = os.getenv("PI_ROOT") or "."
local stubs = dofile(root .. "/Tests/lua/stubs.lua")
stubs.install(root)

-- getWorldPos writes into one of these; boarding.lua makes it on first use.
Vector3f = {
    new = function()
        local v = {_x = 0, _y = 0}
        function v:x() return self._x end
        function v:y() return self._y end
        return v
    end
}

require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end
Core.settings.EntryAtBoardingPoint = true

local r = stubs.reporter()
local check = r.check

-- ---------------------------------------------------------------------------
-- Fakes. A vehicle sits at the origin and never turns, so a script offset IS a
-- world offset. Areas are squares of side 2 centred where the spec says,
-- unless the spec gives a third and fourth number for w and h.
-- ---------------------------------------------------------------------------

local function fakeVehicle(scriptName, spec)
    local areas = spec.areas or {}
    local doors = spec.doors or {}
    local v = {}
    function v:getScript()
        return {
            getFullName = function() return scriptName end,
            getAreaById = function(_, id)
                local a = areas[id]
                return a and {getW = function() return a[3] or 2 end, getH = function() return a[4] or 2 end} or nil
            end
        }
    end
    function v:getAreaCenter(id)
        local a = areas[id]
        return a and {getX = function() return a[1] end, getY = function() return a[2] end} or nil
    end
    function v:getMaxPassengers() return spec.seats or #doors end
    function v:getPassengerPosition(seat, which)
        local d = doors[seat + 1]
        if which ~= "outside" or not d then
            return nil
        end
        return {getOffset = function() return d end}
    end
    function v:getWorldPos(offset, out)
        out._x, out._y = offset[1], offset[2]
        return out
    end
    function v:isInArea(id, chr)
        local a = areas[id]
        return a ~= nil and math.abs(chr:getX() - a[1]) <= (a[3] or 2) / 2
            and math.abs(chr:getY() - a[2]) <= (a[4] or 2) / 2
    end
    -- No getAreaDist: it measures to one corner of the area, not to the
    -- rectangle, and calling it is the bug Core.nearArea replaced.
    return v
end

local function standing(x, y, vehicle)
    return {
        getX = function() return x end,
        getY = function() return y end,
        getVehicle = function() return vehicle end
    }
end

local function describe(point)
    if not point then
        return "anywhere"
    end
    return point.area or (point.door and "door") or "?"
end

-- A van: rear doors, a TruckBed behind it, doors front left and right.
local van = fakeVehicle("Base.Van", {
    areas = {TruckBed = {0, 4}, SeatFrontLeft = {-2, -1}},
    doors = {{-2, -1}, {2, -1}}
})
-- A caravan: a TruckBed like every KI5 trailer, and one side door that all
-- its passengers share.
local caravan = fakeVehicle("Base.Trailer87Scamp13", {
    areas = {TruckBed = {0, 4}},
    doors = {{2, 1}, {2, 1}, {2, 1}}
})
-- Something declaring nothing at all.
local bare = fakeVehicle("Base.Mystery", {seats = 0})
-- Only a trunk door, no TruckBed.
local hatch = fakeVehicle("Base.Hatch", {areas = {TrunkDoor = {0, 3}}, doors = {{2, 0}}})

-- ---------------------------------------------------------------------------
-- Resolution order.
-- ---------------------------------------------------------------------------

check("a van boards at the rear by default", describe(Core.boardingFor(van)), "TruckBed")
check("TrunkDoor stands in when there is no TruckBed", describe(Core.boardingFor(hatch)), "TrunkDoor")
check("unregistered, a caravan would be boarded at the rear", describe(Core.boardingFor(caravan)), "TruckBed")
check("a vehicle declaring nothing is boarded anywhere", Core.boardingFor(bare), nil)

Core.registerBoarding({["Base.Trailer87Scamp13"] = "door"})
check("registered, the caravan is boarded at its door", describe(Core.boardingFor(caravan)), "door")
check("registration is case blind", Core.boarding["base.trailer87scamp13"], "door")

Core.registerBoarding({["Base.Van"] = "SeatFrontLeft"})
check("a registered area wins over the rear", describe(Core.boardingFor(van)), "SeatFrontLeft")

Core.registerBoarding({["Base.Van"] = "NoSuchArea"})
check("an area the vehicle does not declare falls back, not refuses",
    describe(Core.boardingFor(van)), "TruckBed")

Core.registerBoarding({["Base.Mystery"] = "door"})
check("'door' on a vehicle with no doors falls back to anywhere", Core.boardingFor(bare), nil)

Core.registerBoarding({[7] = "door", ["Base.Odd"] = 3})
check("junk entries are ignored", Core.boarding["base.odd"], nil)

-- ---------------------------------------------------------------------------
-- Standing at it.
-- ---------------------------------------------------------------------------

Core.registerBoarding({["Base.Van"] = "TruckBed"})
check("inside the TruckBed is at the rear", Core.atBoardingPoint(van, standing(0.5, 4.5)), true)
check("just outside it, within the slack, still counts", Core.atBoardingPoint(van, standing(0, 5.8)), true)

-- The vanilla livestock trailer: a TruckBed 0.8 x 0.44, a hull about 1.1 wide.
-- The walk to it stops beside it rather than in it, and getAreaDist read the
-- far rear corner as well over a tile away.
local livestock = fakeVehicle("Base.Trailer_Livestock", {areas = {TruckBed = {0, 1.19, 0.8, 0.44}}})
check("beside a thin TruckBed, at the back corner, counts",
    Core.atBoardingPoint(livestock, standing(0.9, 1.2)), true)
check("at the other back corner too", Core.atBoardingPoint(livestock, standing(-0.9, 1.3)), true)
check("halfway along the trailer side does not",
    (Core.atBoardingPoint(livestock, standing(0.9, 0))), false)
check("nor the hitch end", (Core.atBoardingPoint(livestock, standing(0, -1.5))), false)
local ok, point = Core.atBoardingPoint(van, standing(0, -6))
check("in front of the van is not at the rear", ok, false)
check("and the refusal says the back", Core.boardingRefusal(point), "IGUI_PhunInteriors_BoardAtRear")

check("beside the caravan door is at it", Core.atBoardingPoint(caravan, standing(3, 1)), true)
ok, point = Core.atBoardingPoint(caravan, standing(0, 4))
check("round the back of the caravan is not", ok, false)
check("and the refusal says the door", Core.boardingRefusal(point), "IGUI_PhunInteriors_BoardAtDoor")

check("anywhere counts for a vehicle declaring nothing", Core.atBoardingPoint(bare, standing(40, 40)), true)
check("somebody already aboard is always at it", Core.atBoardingPoint(caravan, standing(0, 4, caravan)), true)
check("aboard a DIFFERENT vehicle is not", (Core.atBoardingPoint(caravan, standing(0, 4, van))), false)

check("the walk heads for the nearest door", Core.nearestVehicleDoor(van, standing(3, -1)), 1)

Core.settings.EntryAtBoardingPoint = false
check("with the setting off nothing is asked", Core.boardingFor(caravan), nil)
check("and everybody is at it", Core.atBoardingPoint(caravan, standing(0, 40)), true)

os.exit(r.finish("boarding") == 0 and 0 or 1)
