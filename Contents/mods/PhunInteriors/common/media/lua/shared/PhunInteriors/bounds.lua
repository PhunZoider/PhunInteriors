require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- "Is this square inside one of our rooms?"
--
-- Needed on both sides: the server uses it to sweep fire, the client uses it
-- to refuse destruction actions. Shared so there is one answer.
--
-- This is a lookup over registered slots rather than over leased ones, because
-- it has to work on the client, which does not know who leases what.
--
-- It used to recover the slot index by dividing the offset from the set origin
-- by the pitch, which was two arithmetic ops and free. Placement is an
-- explicit list now, so there is no division to do: Core.slotCandidates buckets
-- the slots by 64 squares and hands back the short list that could contain the
-- point. That matters because this runs on the leash at 4Hz and again on every
-- destroy action the client guards.
-- ---------------------------------------------------------------------------

--- Which slot, if any, contains this point.
-- Returns roomId, index, or nil.
function Core.slotAt(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)

    local candidates = Core.slotCandidates(x, y)
    if not candidates then
        return nil
    end

    for _, candidate in ipairs(candidates) do
        local b = candidate.bounds
        -- allow z+1 so the roof counts as ours for hardening purposes, even
        -- though it is outside the leash
        if z >= b.z and z <= b.z + 1 and
            x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            return candidate.id, candidate.index
        end
    end

    return nil
end

--- Is this point inside any room we own?
function Core.isOurSpace(x, y, z)
    return Core.slotAt(x, y, z) ~= nil
end

--- Is this room's shell unbreakable right now?
--
-- The room's own `hardenShell` when it states one, the HardenShell sandbox
-- option when it does not. The one place that decides, so the destroy guards
-- on the client and the fire sweep on the server cannot disagree about a room.
function Core.shellHardened(roomId)
    local room = roomId and Core.rooms[roomId]
    if room and room.hardenShell ~= nil then
        return room.hardenShell
    end
    return Core.settings.HardenShell and true or false
end

--- Is this point inside a room whose shell is unbreakable?
function Core.isHardenedAt(x, y, z)
    local roomId = Core.slotAt(x, y, z)
    return roomId ~= nil and Core.shellHardened(roomId)
end

--- The same, for an object, by the square it stands on.
function Core.objectIsHardened(object)
    local square = object and object.getSquare and object:getSquare()
    if not square then
        return false
    end
    return Core.isHardenedAt(square:getX(), square:getY(), square:getZ())
end

--- Convenience for the object based callers.
function Core.objectIsOurs(object)
    if not object or not object.getSquare then
        return false
    end
    local square = object:getSquare()
    if not square then
        return false
    end
    return Core.isOurSpace(square:getX(), square:getY(), square:getZ())
end

return Core
