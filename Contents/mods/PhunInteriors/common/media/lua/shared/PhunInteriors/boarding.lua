require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Where you have to stand to get in.
--
-- The vehicle already says where its doors are: every seat's `position
-- outside` is an offset in the vehicle's own frame, and every `area` is a
-- rectangle in it. Both turn with the vehicle, which is why this never names
-- a compass direction -- a caravan's door is only on its east side while it
-- is parked facing north. So a boarding point is always one of those two
-- things, and never a number of ours.
--
--   "TruckBed", "SeatRearRight", ...   a named area: stand in it
--   "door"                             any seat's outside position: stand by
--                                      it, the way ISEnterVehicle requires
--
-- Resolved in this order, and each step only if the vehicle declares it:
--
--   1. what Core.registerBoarding says for this script
--   2. the rear -- TruckBed, then TrunkDoor, the same list Client.groundBeside
--      uses for a rear exit, so a van is entered and left by its back doors
--   3. "door"
--   4. nothing, which means anywhere next to the vehicle, as before
--
-- Step 1 exists because step 2 cannot be derived correctly for everything.
-- Every side-door vehicle bound on this map declares a TruckBed area: the
-- KI5 caravans, the 63Type2Van, both RVs. So the rear is a wrong answer that
-- looks deliberate for exactly the vehicles a side door matters on, and only
-- the author can say so.
--
-- Per SCRIPT, not per binding, because it is a fact about the vehicle alone.
-- A binding is per room and names every vehicle that overflows into that
-- room, so an `entry` on one would apply to vans that merely fall back into a
-- caravan's room -- and one vehicle named by two bindings could be given two
-- answers.
--
-- Shared, and there is one copy. The client walks to the point this names and
-- the server refuses anybody who is not at it; two copies of "where the door
-- is" would disagree about exactly the vehicles that matter.
-- ---------------------------------------------------------------------------

-- The rear, best first. Mirrors AREAS_FOR.rear in client_main.lua.
local REAR = {"TruckBed", "TrunkDoor"}

-- ISEnterVehicle:start refuses a character more than 2 from the seat's
-- outside position, so that is the distance a door means. The extra half is
-- for the server's copy of the position, which can trail the client's.
local DOOR_REACH = 2.5
-- getAreaDist is measured from the rectangle; the same allowance.
local AREA_SLACK = 1.0

--- Say where a script is boarded. `map` is {[script] = "AreaName" | "door"}.
--
-- A later call for the same script replaces the earlier one, the way a
-- binding re-registered under its own id does.
function Core.registerBoarding(map)
    if type(map) ~= "table" then
        Core.logLn("registerBoarding needs a table of script = boarding point")
        return
    end
    for script, point in pairs(map) do
        if type(script) == "string" and type(point) == "string" and point ~= "" then
            Core.boarding[string.lower(script)] = point
        else
            Core.logLn("registerBoarding ignored " .. tostring(script) .. " = " .. tostring(point))
        end
    end
end

local function hasArea(vehicle, area)
    return vehicle.getAreaCenter and vehicle:getAreaCenter(area) ~= nil
end

--- Every seat that has a door, as {seat, x, y}. Empty for a vehicle with none.
--
-- A seat with no outside position is one an author closed off with an empty
-- `position outside {}` block -- see Core.seatIsEnterable -- so it is not a
-- door. Occupied seats still count: somebody sitting in the passenger seat of
-- an RV does not move its door.
-- One vector reused rather than one per call, as vanilla's own
-- distanceToPassengerPosition does. Made on first use, not at load.
local WORLD_POS

function Core.vehicleDoors(vehicle)
    local out = {}
    if not vehicle.getMaxPassengers then
        return out
    end
    WORLD_POS = WORLD_POS or Vector3f.new()
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        local position = vehicle:getPassengerPosition(seat, "outside")
        if position then
            local world = vehicle:getWorldPos(position:getOffset(), WORLD_POS)
            if world then
                table.insert(out, {seat = seat, x = world:x(), y = world:y()})
            end
        end
    end
    return out
end

--- Where this vehicle is boarded: {area = id}, {door = true}, or nil.
--
-- Nil means nowhere in particular, which is what every vehicle got before
-- this existed, and it is also the answer when the setting is off.
function Core.boardingFor(vehicle)
    if not vehicle or not Core.settings.EntryAtBoardingPoint then
        return nil
    end
    local script = vehicle.getScript and vehicle:getScript()
    local full = script and string.lower(tostring(script:getFullName())) or nil

    local stated = full and Core.boarding[full]
    if stated == "door" then
        if #Core.vehicleDoors(vehicle) > 0 then
            return {door = true}
        end
    elseif stated then
        if hasArea(vehicle, stated) then
            return {area = stated}
        end
    end
    if stated then
        -- Falls through rather than refusing: a misspelt area in a table
        -- somebody else wrote should cost precision, not the vehicle.
        Core.debugLn("boarding: " .. tostring(full) .. " names '" .. stated ..
                         "', which it does not declare; using the default")
    end

    for _, area in ipairs(REAR) do
        if hasArea(vehicle, area) then
            return {area = area}
        end
    end
    if #Core.vehicleDoors(vehicle) > 0 then
        return {door = true}
    end
    return nil
end

--- Is this character standing where the vehicle is boarded?
-- Returns true, or false plus the boarding point it wanted.
--
-- Somebody already aboard is always there: moving from a seat into the
-- interior is an internal move, which is the rule Core.vehicleMotionAllows
-- is built on.
function Core.atBoardingPoint(vehicle, character)
    if character:getVehicle() == vehicle then
        return true
    end
    local point = Core.boardingFor(vehicle)
    if not point then
        return true
    end
    if point.area then
        -- isInArea is what vanilla's own server side trunk access gates on
        -- (Vehicles.ContainerAccess); getAreaDist, which vanilla uses for the
        -- animal trailer, gives the slack.
        if vehicle:isInArea(point.area, character) then
            return true
        end
        if vehicle:getAreaDist(point.area, character) <= AREA_SLACK then
            return true
        end
        return false, point
    end
    local cx, cy = character:getX(), character:getY()
    for _, door in ipairs(Core.vehicleDoors(vehicle)) do
        local dx, dy = door.x - cx, door.y - cy
        if dx * dx + dy * dy <= DOOR_REACH * DOOR_REACH then
            return true
        end
    end
    return false, point
end

--- What to tell somebody who is not at the boarding point.
--
-- Two messages rather than the area's name, because an area id is script
-- vocabulary -- nobody playing knows what "SeatRearRight" means -- and the
-- rear is the only one with a plain English name that is always true.
function Core.boardingRefusal(point)
    for _, area in ipairs(REAR) do
        if point and point.area == area then
            return "IGUI_PhunInteriors_BoardAtRear"
        end
    end
    return "IGUI_PhunInteriors_BoardAtDoor"
end

--- The door nearest this character, or nil. What the walk heads for.
function Core.nearestVehicleDoor(vehicle, character)
    local best, bestDistance
    local cx, cy = character:getX(), character:getY()
    for _, door in ipairs(Core.vehicleDoors(vehicle)) do
        local dx, dy = door.x - cx, door.y - cy
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then
            best, bestDistance = door.seat, distance
        end
    end
    return best
end

return Core
