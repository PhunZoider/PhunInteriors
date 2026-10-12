if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Doors = {}
Core.modules.doors = Doors

-- ---------------------------------------------------------------------------
-- Shutting the way out behind the last tenant.
--
-- The way out of a room is walking through its door, so every exit leaves
-- that door standing open, and the next visit finds it so. Closed on the way
-- back IN rather than on the way out, for two reasons. Leaving, the tenant is
-- still in the doorway as far as the server knows, and the leash fires the
-- moment they cross the edge, mid stride. And arriving is the one moment
-- already proven to have the room loaded: the leash drives this off the same
-- "standing inside" reading that capture, scrub and the collectors ride. Since
-- nobody can see the room in between, shut on arrival and shut on departure
-- look the same to everybody.
--
-- Only when the arrival has the room to themselves. Somebody already in there
-- may have left the door open on purpose, or be about to walk through it.
--
-- The close is vanilla's own: IsoDoor:ToggleDoorActual(character), which is
-- what a player's click ends in. It is the one call that handles a double door
-- and a garage door as a set, refuses a barricaded or obstructed one, and
-- ends in sync() -- which server side sends to every connection. ToggleDoor
-- is a one line alias for it; ToggleDoorSilent flips a flag and a sprite and
-- tells nobody.
--
-- Only IsoDoor. A door a player built is an IsoThumpable and would need its own
-- branch, and the doors this is for are the map's.
-- ---------------------------------------------------------------------------

--- Does a door on this square, facing this way, lead out of the floor?
--
-- A north door lies on the edge between its square and the one north of it, a
-- west door on the edge between its square and the one west. The door leads
-- out when exactly one of the two is floor: both is an internal door, such as
-- a camper's bathroom, and is the tenant's business.
function Doors.isExterior(floor, x, y, north)
    local inside = Core.inBounds(floor, x, y, floor.z)
    local beyond
    if north then
        beyond = Core.inBounds(floor, x, y - 1, floor.z)
    else
        beyond = Core.inBounds(floor, x - 1, y, floor.z)
    end
    return inside ~= beyond
end

--- Is anybody besides `key` inside the room this holder leases?
function Doors.othersInside(key, holder)
    for other, occupancy in pairs(Core.occupants) do
        if other ~= key and occupancy.vehicleId == holder then
            return true
        end
    end
    return false
end

--- Close every open door leading out of this slot. Returns how many it closed.
--
-- Scans the footprint rather than the floor, because a south or east door
-- stands on the square beyond the floor, and only the room's own level.
function Doors.closeExterior(roomId, index, character)
    local room = Core.rooms[roomId]
    local bounds = room and Core.slotBounds(room, index)
    local floor = room and Core.slotFloor(room, index)
    if not bounds or not floor then
        return 0
    end
    local cell = getCell()
    local closed = 0
    for x = bounds.x1, bounds.x2 do
        for y = bounds.y1, bounds.y2 do
            local square = cell:getGridSquare(x, y, bounds.z)
            local objects = square and square:getObjects()
            if objects then
                -- Collected first: toggling rewrites the object's sprite, and a
                -- double door toggles its other leaves on neighbouring squares.
                local doors = {}
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoDoor") then
                        doors[#doors + 1] = object
                    end
                end
                for _, door in ipairs(doors) do
                    -- Asked again per door, since closing one leaf of a double
                    -- door closes the rest with it.
                    if door:IsOpen() and Doors.isExterior(floor, x, y, door:getNorth()) then
                        local ok, err = pcall(door.ToggleDoorActual, door, character)
                        if not ok then
                            Core.logLn(string.format("could not close the door at %d,%d,%d in %s#%s: %s", x, y,
                                bounds.z, tostring(roomId), tostring(index), tostring(err)))
                        elseif not door:IsOpen() then
                            closed = closed + 1
                        end
                    end
                end
            end
        end
    end
    return closed
end

--- Close the doors behind a tenant who has just arrived in an empty room.
function Doors.closeBehind(player, occupancy)
    local key = Core.playerKey(player)
    if occupancy.vehicleId and Doors.othersInside(key, occupancy.vehicleId) then
        return 0
    end
    local closed = Doors.closeExterior(occupancy.room, occupancy.index, player)
    if closed > 0 then
        Core.debugLn(string.format("closed %d door(s) in %s#%s for %s", closed, tostring(occupancy.room),
            tostring(occupancy.index), tostring(key)))
    end
    return closed
end

return Doors
