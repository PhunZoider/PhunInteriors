if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Weight = {}
Core.modules.weight = Weight

-- ---------------------------------------------------------------------------
-- The bottomless boot.
--
-- PZ already folds real vehicle container contents and occupant mass into a
-- vehicle physics mass. An instanced room is a container the game knows
-- nothing about, so interior loot is free to carry. This closes that.
--
-- WeightFactor is a percentage, so an admin can dial it to taste or to zero.
--
-- Caveat worth knowing: this affects handling, acceleration and braking but
-- NOT fuel burn. The consumption formula in vanilla Vehicles.lua reads
-- vehicle:getScript():getMass(), the static value from the vehicle definition,
-- not runtime mass. A matching fuel penalty is separate work.
-- ---------------------------------------------------------------------------

--- Total weight of everything loose or contained inside a slot.
function Weight.ofSlot(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set then
        return 0
    end

    local bounds = Core.slotBounds(set, index)
    local total = 0

    for x = bounds.x1, bounds.x2 do
        for y = bounds.y1, bounds.y2 do
            local square = getCell():getGridSquare(x, y, bounds.z)
            if square then
                -- items on the floor
                local objects = square:getWorldObjects()
                if objects then
                    for i = 0, objects:size() - 1 do
                        local worldItem = objects:get(i)
                        local item = worldItem and worldItem:getItem()
                        if item then
                            total = total + item:getActualWeight()
                        end
                    end
                end

                -- items in whatever containers the room holds
                local containerObjects = square:getObjects()
                for i = 0, containerObjects:size() - 1 do
                    local object = containerObjects:get(i)
                    local container = object and object.getContainer and object:getContainer()
                    if container then
                        total = total + container:getContentsWeight()
                    end
                end
            end
        end
    end

    return total
end

--- Push our share of the interior weight onto the vehicle.
--
-- We compose additively over whatever mass the vehicle already has and track
-- only our own delta. Caching an absolute baseline and restoring it, which is
-- the common approach, stomps any other mod touching mass on the same vehicle.
function Weight.apply(vehicle, interiorWeight)
    if not vehicle then
        return
    end

    local factor = tonumber(Core.settings.WeightFactor) or 0
    local vmd = vehicle:getModData()
    local applied = tonumber(vmd[Core.consts.massDeltaKey]) or 0
    local want = (tonumber(interiorWeight) or 0) * (factor / 100)

    if math.abs(want - applied) < 0.01 then
        return applied
    end

    local ok = pcall(function()
        vehicle:setMass(vehicle:getMass() - applied + want)
        vehicle:setInitialMass(vehicle:getInitialMass() - applied + want)
        vehicle:updateTotalMass()
    end)

    if not ok then
        Core.debugLn("could not set mass on vehicle, leaving it alone")
        return applied
    end

    vmd[Core.consts.massDeltaKey] = want
    vehicle:transmitModData()

    Core.debugLn(string.format("mass delta %.1f -> %.1f (%.0f%% of %.1f)",
        applied, want, factor, tonumber(interiorWeight) or 0))
    return want
end

--- Recompute and apply for a vehicle that owns a slot.
function Weight.refresh(vehicle)
    if not vehicle then
        return
    end
    local vehicleId = Core.vehicleId(vehicle, false)
    if not vehicleId then
        return
    end
    local assignment = Slots.find(vehicleId)
    if not assignment then
        return
    end
    Weight.apply(vehicle, Weight.ofSlot(assignment.roomSet, assignment.index))
end

--- Remove our contribution entirely, eg when a lease is released.
function Weight.clear(vehicle)
    if vehicle then
        Weight.apply(vehicle, 0)
    end
end

return Weight
