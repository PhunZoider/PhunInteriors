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

--- The real IsoGenerator on a square, if there is one.
local function generatorOn(square)
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

--- Anything on this square that looks like a generator but is not one.
--
-- A scrub rebuilds a square from its blueprint, and a generator sprite
-- recreated by sprite name comes back as a plain IsoObject -- a picture of a
-- generator, the same trap that cost us working light switches. Left alone it
-- would sit there while we placed a second, real one beside it.
local function deadGeneratorOn(square)
    local objects = square and square:getObjects()
    if not objects then
        return nil
    end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local sprite = object and object:getSprite()
        local name = sprite and sprite:getName()
        -- The sprite set MOGenerator.lua keys off.
        if name and string.find(name, "^appliances_misc_01_")
            and not instanceof(object, "IsoGenerator") then
            return object
        end
    end
    return nil
end

--- The generator serving a slot, placing one if it has gone.
--
-- Position is fixed data: set.power, captured by the authoring tool and
-- emitted into the blueprint. It does not move. What can happen is that the
-- generator stops existing -- it caught fire, it blew up, a scrub rebuilt the
-- square from a blueprint and left an inert copy -- and a room whose lights
-- never come back because of that is worse than one that quietly repairs
-- itself.
--
-- Creating one follows vanilla's own recipe from MOGenerator.lua, which is
-- what turns a map-placed sprite into a real generator in the first place.
function Power.ensureGenerator(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set or not set.powered then
        return nil
    end

    local at = Core.slotPower(set, index)
    local square = getCell():getGridSquare(at.x, at.y, at.z)
    if not square then
        -- Chunk is not loaded. Not a failure, just not now.
        return nil
    end

    local found = generatorOn(square)
    if found then
        return found
    end

    local impostor = deadGeneratorOn(square)
    if impostor then
        square:transmitRemoveItemFromSquare(impostor)
        Core.debugLn(string.format("%s#%s had a generator-shaped object that was not one; removed it",
            tostring(roomSetId), tostring(index)))
    end

    local item = instanceItem("Base.Generator")
    if not item then
        Core.logLn("could not create a Base.Generator item")
        return nil
    end
    item:setCondition(100)
    item:getModData().fuel = 0

    local generator = IsoGenerator.new(item, getCell(), square)
    -- The constructor adds it to the square itself; MOGenerator.lua has a
    -- commented-out AddSpecialObject saying as much.
    generator:transmitCompleteItemToClients()

    Core.logLn(string.format("%s#%s had no generator at %d,%d,%d; placed one",
        tostring(roomSetId), tostring(index), at.x, at.y, at.z))
    return generator
end

--- Start the room's generator on the charge the vehicle had at the door.
--
-- Returns true when there is nothing further to do, including when there is no
-- generator to find -- that is a map problem, and retrying will not fix it.
function Power.engage(occupancy)
    local set = Core.roomSets[occupancy.roomSet]
    if not Core.settings.PowerBinding or not set or not set.powered then
        return true
    end

    local generator = Power.ensureGenerator(occupancy.roomSet, occupancy.index)
    if not generator then
        return true
    end

    local maxFuel = tonumber(generator:getMaxFuel()) or 0
    if maxFuel <= 0 then
        return true
    end

    -- Kept healthy on every visit. A generator that degrades would eventually
    -- break or burn, and the failure it produces -- a room that stops having
    -- power for no reason the tenant can see or fix, since they cannot reach
    -- it -- is not a mechanic, it is a fault report.
    generator:setCondition(100)

    local fuel = (occupancy.batteryAtEntry or 0) * maxFuel
    generator:setFuel(fuel)
    -- setActivated does the rest itself: it registers the generator position
    -- with the chunk, which is what isGeneratorPoweringSquare reads, calls
    -- setSurroundingElectricity, and syncs to clients. Calling those separately
    -- is redundant.
    --
    -- It also marks the building toxic for a generator on a non-exterior
    -- square. Nothing to do about that here: the power square sits above the
    -- room and outside the leash by design, so it is exterior, nobody ever
    -- stands next to it, and no fumes are produced.
    generator:setActivated(fuel > 0)

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

    local set = Core.roomSets[occupancy.roomSet]
    local at = set and Core.slotPower(set, occupancy.index)
    local square = at and getCell():getGridSquare(at.x, at.y, at.z)
    local generator = generatorOn(square)
    if not generator then
        -- Blown up, or the chunk went while we were not looking. Deliberately
        -- not replaced here: charging for fuel we cannot measure would be a
        -- guess, and the next entry puts a fresh one in anyway.
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
