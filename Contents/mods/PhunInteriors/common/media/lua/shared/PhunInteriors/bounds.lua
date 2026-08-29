require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- "Is this square inside one of our rooms?"
--
-- Needed on both sides: the server uses it to sweep fire, the client uses it
-- to refuse destruction actions. Shared so there is one answer.
--
-- This is a cheap arithmetic test against each room set rather than a lookup
-- over leased slots, because it has to work on the client, which does not
-- know who leases what.
-- ---------------------------------------------------------------------------

--- Which slot, if any, contains this point.
-- Returns roomSetId, index, or nil.
function Core.slotAt(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)

    for id, set in pairs(Core.roomSets) do
        -- allow z+1 so the roof counts as ours for hardening purposes, even
        -- though it is outside the leash
        if z >= set.origin.z and z <= set.origin.z + 1 then
            local dx = x - set.origin.x
            local dy = y - set.origin.y

            local index
            if set.pitch.x ~= 0 then
                index = math.floor(dx / set.pitch.x)
            elseif set.pitch.y ~= 0 then
                index = math.floor(dy / set.pitch.y)
            else
                index = 0
            end

            if index >= 0 and index <= set.count then
                local bounds = Core.slotBounds(set, index)
                -- deliberately ignores z here; bounds.z is the floor and we
                -- already accepted the roof above
                if x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2 then
                    return id, index
                end
            end
        end
    end

    return nil
end

--- Is this point inside any room we own?
function Core.isOurSpace(x, y, z)
    return Core.slotAt(x, y, z) ~= nil
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
