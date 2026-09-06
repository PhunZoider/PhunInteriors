if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Power = {}
Core.modules.power = Power

-- ---------------------------------------------------------------------------
-- The room runs off the vehicle battery.
--
-- An interior whose lights work forever is a free safehouse. Binding them to
-- the battery makes the room cost something to use, and gives a flat battery a
-- consequence rather than a locked door: you can still get in, it is just
-- dark.
--
-- The mechanism is a real generator, because there is no alternative.
-- square:haveElectricity() reads no field at all -- it is
-- chunk:isGeneratorPoweringSquare(x, y, z) -- so generator power is only ever
-- an actual, activated IsoGenerator registered in the chunk. setHaveElectricity
-- looks like the shortcut and is not: it ignores its argument entirely.
--
-- The mapper places one. Vanilla's MOGenerator.lua turns the sprites
-- appliances_misc_01_0 through _15 into real IsoGenerator objects on map load,
-- server side, with fuel 0 and condition 100. So a generator sprite anywhere
-- in the room is all that is needed, and it arrives empty -- which is exactly
-- right, because the fuel in it is our projection of the battery.
--
-- Where in the room does not matter. set.power is a hint from the authoring
-- tool, not a location: a mapper may well put the thing on the floor in a
-- corner. The whole slot is searched, and searched again on every entry rather
-- than cached, because between two visits a map can be rebuilt, a room
-- scrubbed, or the generator carried off by the last tenant.
--
-- Fuel is the battery. A full battery fills the tank, an empty one leaves it
-- dry, and whatever the engine burns while the tenant is inside is charged
-- back to the battery on the way out.
--
-- That last step composes additively, the same discipline as weight: we take
-- off only what *we* burned. Somebody else driving the van while you are
-- inside moves the charge underneath us, and their drain has to survive ours.
-- ---------------------------------------------------------------------------

--- The battery item feeding this vehicle, or nil.
--
-- A trailer has no battery of its own and runs off whatever is towing it,
-- which is worth handling because a towed interior is a case supported
-- everywhere else in this mod.
function Power.battery(vehicle)
    if not vehicle then
        return nil
    end
    local part = vehicle:getPartById("Battery")
    local item = part and part:getInventoryItem()
    if item then
        return item
    end
    local tower = vehicle:getVehicleTowedBy()
    part = tower and tower:getPartById("Battery")
    return part and part:getInventoryItem() or nil
end

--- Charge as 0..1. A vehicle with no battery reads flat, which is the truth.
function Power.charge(vehicle)
    local battery = Power.battery(vehicle)
    if not battery then
        return 0
    end
    local charge = tonumber(battery:getUsedDelta()) or 0
    return math.max(0, math.min(1, charge))
end

--- The generator serving a slot, wherever it happens to be.
function Power.findGenerator(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set then
        return nil
    end

    local function generatorOn(x, y, z)
        local square = getCell():getGridSquare(x, y, z)
        local objects = square and square:getObjects()
        if not objects then
            return nil
        end
        for i = 0, objects:size() - 1 do
            local object = objects:get(i)
            if object and instanceof(object, "IsoGenerator") then
                return object
            end
        end
        return nil
    end

    -- Where the authoring tool said it would be, if that still holds.
    local hint = Core.slotPower(set, index)
    local found = generatorOn(hint.x, hint.y, hint.z)
    if found then
        return found
    end

    -- Otherwise anywhere in the room, both levels.
    local bounds = Core.slotBounds(set, index)
    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                found = generatorOn(x, y, z)
                if found then
                    return found
                end
            end
        end
    end

    return nil
end

--- Start the room's generator on the charge the vehicle had at the door.
--
-- Returns true when there is nothing further to do, including when there is no
-- generator to find -- that is a map problem, and retrying will not fix it.
function Power.engage(occupancy)
    if not Core.settings.PowerBinding then
        return true
    end

    local generator = Power.findGenerator(occupancy.roomSet, occupancy.index)
    if not generator then
        Core.logLn(string.format(
            "%s#%s has no generator, so the room has no power. Place a generator "
            .. "sprite (appliances_misc_01_0 to _15) in it on the map.",
            tostring(occupancy.roomSet), tostring(occupancy.index)))
        return true
    end

    local maxFuel = tonumber(generator:getMaxFuel()) or 0
    if maxFuel <= 0 then
        return true
    end

    local fuel = (occupancy.batteryAtEntry or 0) * maxFuel
    generator:setFuel(fuel)
    -- setActivated does the rest itself: it registers the generator position
    -- with the chunk, which is what isGeneratorPoweringSquare reads, calls
    -- setSurroundingElectricity, and syncs to clients. Calling those separately
    -- is redundant.
    generator:setActivated(fuel > 0)

    -- It also marks the building toxic, because a generator running in an
    -- enclosed space poisons it. Correct for a petrol generator in somebody's
    -- kitchen, wrong here: this one is a fiction standing in for the vehicle's
    -- electrical system, and a sealed room three tiles wide would kill the
    -- tenant it exists to shelter. setActivated passes its argument straight
    -- through to setToxic, so shutting down clears it again; this clears it
    -- while running.
    local square = generator:getSquare()
    local building = square and square:getBuilding()
    if building and building:isToxic() then
        building:setToxic(false)
    end

    -- What it started with, so the way out can charge for the difference.
    occupancy.fuelAtStart = fuel
    occupancy.generatorMaxFuel = maxFuel

    Core.debugLn(string.format("%s#%s generator filled to %.1f/%.1f from a %.0f%% battery",
        tostring(occupancy.roomSet), tostring(occupancy.index), fuel, maxFuel,
        (occupancy.batteryAtEntry or 0) * 100))
    return true
end

--- Shut the generator down and report what it burned, as battery charge.
--
-- Called on the way out, while the room is still loaded. The vehicle almost
-- certainly is not, so the number is handed to the arrival report to apply.
function Power.disengage(occupancy)
    if not Core.settings.PowerBinding or not occupancy.fuelAtStart then
        return 0
    end

    local generator = Power.findGenerator(occupancy.roomSet, occupancy.index)
    if not generator then
        -- Carried off, or the chunk went while we were not looking. Charging
        -- for fuel we cannot measure would be a guess.
        return 0
    end

    local maxFuel = occupancy.generatorMaxFuel or tonumber(generator:getMaxFuel()) or 0
    local left = tonumber(generator:getFuel()) or 0
    local burned = math.max(0, occupancy.fuelAtStart - left)

    -- Off, empty and dark until somebody comes back. Deactivating also clears
    -- the toxic flag the engine set when it started.
    generator:setFuel(0)
    generator:setActivated(false)

    if maxFuel <= 0 then
        return 0
    end

    local factor = tonumber(Core.settings.PowerDrainFactor) or 100
    local used = (burned / maxFuel) * (factor / 100)

    Core.debugLn(string.format("%s#%s burned %.1f of %.1f fuel -> %.1f%% of a battery",
        tostring(occupancy.roomSet), tostring(occupancy.index), burned, maxFuel, used * 100))
    return used
end

--- Take the room's consumption off the vehicle battery.
--
-- Subtractive, never absolute. Whatever else moved the charge while the tenant
-- was inside -- somebody driving it, a charger, another mod -- survives.
function Power.applyToBattery(vehicle, used)
    used = tonumber(used) or 0
    if used <= 0 then
        return 0
    end
    local battery = Power.battery(vehicle)
    if not battery then
        return 0
    end

    local before = math.max(0, math.min(1, tonumber(battery:getUsedDelta()) or 0))
    local after = math.max(0, before - used)
    battery:setUsedDelta(after)

    Core.debugLn(string.format("battery %.0f%% -> %.0f%% for the interior",
        before * 100, after * 100))
    return before - after
end

return Power
