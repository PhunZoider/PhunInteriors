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

--- The carry weight of a placed object, if it is something a player put down.
--
-- Vanilla's own formula, from ISMoveableSpriteProps: PickUpWeight over ten,
-- defaulting to 50 when the sprite does not say. IsMoveAble is what separates
-- a forge somebody dragged in from the wall behind it.
local function moveableWeight(object)
    local sprite = object and object:getSprite()
    local props = sprite and sprite:getProperties()
    if not props or not props:has("IsMoveAble") then
        return 0
    end
    local raw = props:has("PickUpWeight") and tonumber(props:get("PickUpWeight")) or 50
    return raw / 10
end

--- Total weight of everything the tenant added to a slot.
--
-- Three things count, and one deliberately does not:
--
--   loose items on the floor
--   the contents of any container, including the room's own cupboards
--   objects the tenant placed -- a forge, a generator, a crate
--   *not* the room's own fixtures, which are free
--
-- The last distinction is why this reads the blueprint. Everything the
-- blueprint expects is part of the room and always there, so charging for it
-- would just be a constant tax on using the feature at all. Anything beyond
-- what the blueprint expects was carried in, and carrying it is exactly the
-- thing this mechanic exists to make cost something.
function Weight.ofSlot(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set then
        return 0
    end

    local Manifest = require "PhunInteriors/manifest"
    local blueprint = Manifest.forSlot(roomSetId, index)
    local bounds = Core.slotBounds(set, index)
    local origin = Core.slotOrigin(set, index)

    -- The room itself, before anything is put in it. Zero by default, so a
    -- room set that says nothing costs nothing to have.
    local total = tonumber(set.baseWeight) or 0

    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                if square then
                    -- items dropped on the floor
                    local worldObjects = square:getWorldObjects()
                    if worldObjects then
                        for i = 0, worldObjects:size() - 1 do
                            local worldItem = worldObjects:get(i)
                            local item = worldItem and worldItem:getItem()
                            if item then
                                total = total + item:getActualWeight()
                            end
                        end
                    end

                    -- what the room is supposed to hold here, so the rest can
                    -- be recognised as brought in
                    local key = (x - origin.x) .. "," .. (y - origin.y) .. "," .. (z - origin.z)
                    local expected = {}
                    for _, name in ipairs(Manifest.spritesAt(blueprint, key) or {}) do
                        expected[name] = (expected[name] or 0) + 1
                    end

                    local floor = square:getFloor()
                    local objects = square:getObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if object and object ~= floor then
                            -- contents cost wherever they are stored
                            local container = object.getContainer and object:getContainer()
                            if container then
                                total = total + container:getContentsWeight()
                            end

                            local sprite = object:getSprite()
                            local name = sprite and sprite:getName()
                            if name and (expected[name] or 0) > 0 then
                                expected[name] = expected[name] - 1
                            else
                                total = total + moveableWeight(object)
                            end
                        end
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
        -- Silence here reads as "the weight was never calculated", which is
        -- the one thing it does not mean: the room is scanned on every exit,
        -- and this only skips pushing an identical number back at the engine.
        Core.debugLn(string.format(
            "mass unchanged at %.1f (%.0f%% of %.1f), nothing to apply",
            applied, factor, tonumber(interiorWeight) or 0))
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

    Core.debugLn(string.format("mass delta %.1f -> %.1f (%.0f%% of %.1f)", applied, want, factor,
        tonumber(interiorWeight) or 0))
    return want
end

-- ---------------------------------------------------------------------------
-- Applying the mass needs the vehicle loaded, and the moment a player leaves a
-- room it never is: the vehicle's chunk was unloaded the whole time they were
-- inside. Weight.refresh was wired to run exactly there, so it never ran once
-- -- no "mass delta" line has ever appeared in a log.
--
-- The room, by contrast, is loaded at that moment, because the player is
-- standing in it. So the weight is measured on the way out, and applied when
-- the player reports that they have landed back at the vehicle -- see
-- Transit.arrived. That report is the same event that loads the chunk, so
-- there is nothing here to poll for. This used to be a once-a-second sweep
-- looking for the vehicle to reappear, which was the same wait dressed up as
-- a timer.
-- ---------------------------------------------------------------------------

--- What we are currently charging each leased vehicle, for the admin report.
--
-- Reads the stored delta rather than the vehicle, because the whole point is
-- that the vehicle is usually not loaded.
function Weight.report()
    local lines = {}

    for vehicleId, assignment in pairs(Slots.store().assignments) do
        local position = assignment.lastKnownVehiclePos
        local vehicle = position and Core.vehicleNear(position.x, position.y, position.z, vehicleId)
        local applied = 0
        if vehicle then
            applied = tonumber(vehicle:getModData()[Core.consts.massDeltaKey]) or 0
        end
        table.insert(lines,
            string.format("%s -> %s#%s, carrying %.1f%s", vehicleId, assignment.roomSet, assignment.index, applied,
                vehicle and "" or " (vehicle not loaded, delta unread)"))
    end

    if #lines == 0 then
        table.insert(lines, "no leases")
    end
    table.insert(lines, string.format("weight factor %s%%", tostring(Core.settings.WeightFactor)))
    return lines
end

return Weight
