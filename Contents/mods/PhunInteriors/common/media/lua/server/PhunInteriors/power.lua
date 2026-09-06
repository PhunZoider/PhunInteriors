if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
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
-- It has to be a real generator. square:haveElectricity() reads no field -- it
-- is chunk:isGeneratorPoweringSquare(x, y, z) -- so generator power is only
-- ever an activated IsoGenerator registered in the chunk. setHaveElectricity
-- looks like the shortcut and is not: it ignores its argument entirely.
--
-- ---------------------------------------------------------------------------
-- Who does the arithmetic
--
-- Almost none of it is ours. IsoGenerator.update() burns
--
--     totalPowerUsing * SandboxOptions.generatorFuelConsumption
--
-- for every world hour since its lastHour, and totalPowerUsing is accumulated
-- by setSurroundingElectricity from the objects actually within range. So an
-- empty room draws nothing and burns nothing; put a fridge in it and it burns.
-- That is exactly the behaviour we want, and the engine already has it.
--
-- lastHour is compared against the world age rather than ticked, so the burn
-- also catches up for time the chunk spent unloaded. Two days away costs two
-- days of fuel the moment the room loads again.
--
-- ---------------------------------------------------------------------------
-- The tank is a buffer, not a fuel gauge
--
-- Because of that catch-up, sizing the tank to the battery does not work: half
-- a battery buys half a tank, and returning after a couple of days empties it
-- while the van outside is perfectly healthy. The tenant loses a fridge full
-- of food for a reason they cannot see.
--
-- So the tank is topped to *full* whenever there is any charge to draw on, and
-- the battery is the limiting resource. Battery alive means the generator is
-- golden; battery flat means a dark room. The only way to run dry with charge
-- in the battery is an absence long enough to burn a whole tank, which takes
-- days of continuous draw and reads honestly as having been away too long.
--
-- ---------------------------------------------------------------------------
-- The ledger
--
-- The two halves are never loaded at the same time. While the tenant is inside
-- the room, their vehicle is 10,000 tiles away and unloaded; while they are
-- driving it, the room is. Neither side can read the other, so each records
-- what it saw and the debt is carried between them on the lease.
--
--   fuelOwed      fuel burnt that the battery has not yet paid for
--   fuelLast      the tank level when the room was last looked at
--   batteryKnown  the last true reading taken off the battery
--
-- Settle whenever either side happens to be loaded. The room half runs off the
-- leash, which is already the hook that means "the chunk is loaded and the
-- tenant is standing in it". The vehicle half runs off entry, off the arrival
-- report, and off every position push from the tracker -- and that last one is
-- free, because the tracker only ever fires when somebody is driving a leased
-- vehicle, which is precisely when it is loaded.
--
-- Nothing here is periodic. RV Interior, which solved this first, sweeps every
-- in-game hour over getCell():getVehicles() -- and that sweep is dead on B42,
-- because the Set it walks has no get(i).
-- ---------------------------------------------------------------------------

--- The battery part feeding this vehicle, and the vehicle that owns it.
--
-- Both are needed: the charge lives on the part's inventory item, and the
-- transmit that tells clients about a change is a method on the *vehicle*,
-- taking the part. They are not always the same vehicle -- a trailer has no
-- battery of its own and runs off whatever is towing it, which is worth
-- handling because a towed interior is supported everywhere else here.
--
-- getBattery rather than getPartById("Battery"): it is the purpose-built
-- accessor and the one vanilla's own VehicleUtils.chargeBattery uses.
function Power.batteryPart(vehicle)
    if not vehicle then
        return nil, nil
    end
    local part = vehicle:getBattery()
    if part and part:getInventoryItem() then
        return part, vehicle
    end
    local tower = vehicle:getVehicleTowedBy()
    part = tower and tower:getBattery()
    if part and part:getInventoryItem() then
        return part, tower
    end
    return nil, nil
end

--- The battery item feeding this vehicle, or nil.
function Power.battery(vehicle)
    local part = Power.batteryPart(vehicle)
    return part and part:getInventoryItem() or nil
end

-- Reading and writing a battery's charge.
--
-- getCurrentUsesFloat / setCurrentUsesFloat, both declared on InventoryItem
-- itself, so they are safe whatever a mod has installed in the battery slot.
--
-- Not getUsedDelta, which is what RV Interior uses and what this called first:
-- it does not exist in B42 outside Clothing, and a car battery is a
-- DrainableComboItem. That class declares setUsedDelta and no getter at all,
-- so the write worked and the read threw. Vanilla's own asymmetry hides this:
-- Vehicles.lua:1317 writes with setUsedDelta while ISVehicleRoadtripDebug
-- reads with getCurrentUsesFloat. setUsedDelta turns out to be a one-line
-- alias for setCurrentUsesFloat, and getCurrentUsesFloat is uses/getMaxUses,
-- so this pair is the same value from both ends.
local function readCharge(battery)
    return math.max(0, math.min(1, tonumber(battery:getCurrentUsesFloat()) or 0))
end

local function writeCharge(battery, charge)
    battery:setCurrentUsesFloat(math.max(0, math.min(1, charge)))
end

--- Charge as 0..1. A vehicle with no battery reads flat, which is the truth.
function Power.charge(vehicle)
    local battery = Power.battery(vehicle)
    if not battery then
        return 0
    end
    return readCharge(battery)
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
-- recreated by name comes back as a plain IsoObject -- a picture of a
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
-- Returns the generator, and whether it had to be created -- the caller needs
-- that, because a fresh one starts empty and the ledger must not read the
-- difference as fuel somebody burned.
--
-- Position is fixed data: set.power, from the authoring tool, emitted into the
-- blueprint. It does not move. What can change is whether the generator still
-- exists -- it caught fire, it blew up, a scrub left an inert copy -- and a
-- room whose lights never come back because of that is worse than one that
-- quietly repairs itself.
function Power.ensureGenerator(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set or not set.powered then
        return nil, false
    end

    local at = Core.slotPower(set, index)
    local square = getCell():getGridSquare(at.x, at.y, at.z)
    if not square then
        -- Chunk is not loaded. Not a failure, just not now.
        return nil, false
    end

    local found = generatorOn(square)
    if found then
        return found, false
    end

    local impostor = deadGeneratorOn(square)
    if impostor then
        square:transmitRemoveItemFromSquare(impostor)
        Core.debugLn(string.format("%s#%s had a generator-shaped object that was not one; removed it",
            tostring(roomSetId), tostring(index)))
    end

    -- Vanilla's own recipe, from MOGenerator.lua.
    local item = instanceItem("Base.Generator")
    if not item then
        Core.logLn("could not create a Base.Generator item")
        return nil, false
    end
    item:setCondition(100)
    item:getModData().fuel = 0

    local generator = IsoGenerator.new(item, getCell(), square)
    -- The constructor adds it to the square itself; MOGenerator.lua has a
    -- commented-out AddSpecialObject saying as much.
    generator:transmitCompleteItemToClients()

    Core.logLn(string.format("%s#%s had no generator at %d,%d,%d; placed one",
        tostring(roomSetId), tostring(index), at.x, at.y, at.z))
    return generator, true
end

--- What the battery would read if the outstanding debt were settled now.
--
-- The room cannot see the battery, so this is how it knows whether there is
-- still anything to draw on. Without it, a tenant sitting inside long enough
-- to empty a full tank would watch the lights die while their van sat outside
-- with a charged battery.
local function projectedCharge(assignment)
    local known = tonumber(assignment.batteryKnown) or 0
    local owed = tonumber(assignment.fuelOwed) or 0
    local maxFuel = tonumber(assignment.generatorMaxFuel) or 0
    if maxFuel <= 0 then
        return known
    end
    local factor = tonumber(Core.settings.PowerDrainFactor) or 100
    return known - ((owed / maxFuel) * (factor / 100))
end
Power.projectedCharge = projectedCharge

--- Read the generator, bank what it burned, and top it up if there is charge.
--
-- Called while the room is loaded, which is the only time any of this is
-- readable. Safe to call repeatedly: it measures a difference, so a second
-- call a moment later banks nothing.
function Power.syncRoom(roomSetId, index, vehicleId)
    if not Core.settings.PowerBinding then
        return
    end
    local set = Core.roomSets[roomSetId]
    if not set or not set.powered then
        return
    end
    local assignment = vehicleId and Slots.find(vehicleId)
    if not assignment then
        return
    end

    local generator, created = Power.ensureGenerator(roomSetId, index)
    if not generator then
        return
    end

    local maxFuel = tonumber(generator:getMaxFuel()) or 0
    if maxFuel <= 0 then
        return
    end
    assignment.generatorMaxFuel = maxFuel

    -- Kept healthy on every visit. A generator that degrades eventually breaks
    -- in a room nobody can reach it in, and a room that loses power for no
    -- visible or fixable reason is a fault report rather than a mechanic.
    generator:setCondition(100)

    local now = tonumber(generator:getFuel()) or 0

    -- What it burned since we last looked. A generator we have only just
    -- placed starts empty and owes nothing -- reading its zero as a full
    -- tank's worth of consumption would bill the tenant for our own repair.
    if not created and assignment.fuelLast then
        local burnt = math.max(0, assignment.fuelLast - now)
        if burnt > 0 then
            assignment.fuelOwed = (tonumber(assignment.fuelOwed) or 0) + burnt
            Core.debugLn(string.format("%s#%s burned %.1f fuel; %.1f owed",
                tostring(roomSetId), tostring(index), burnt, assignment.fuelOwed))
        end
    end

    -- Fill it if there is anything left to draw on. Full, not proportional:
    -- the battery is the limiting resource, the tank is only a buffer.
    local fuel = now
    if projectedCharge(assignment) > 0 then
        fuel = maxFuel
    else
        fuel = 0
    end
    generator:setFuel(fuel)
    -- setActivated does the rest itself: registers the position with the
    -- chunk, which is what isGeneratorPoweringSquare reads, calls
    -- setSurroundingElectricity, and syncs to clients.
    generator:setActivated(fuel > 0)

    assignment.fuelLast = fuel
end

--- Settle the debt against the real battery.
--
-- Called whenever the vehicle is loaded and in hand: on entry, on the arrival
-- report, and on every position push from the tracker. Subtractive, never
-- absolute -- whatever else moved the charge while the tenant was inside,
-- somebody driving it or a charger or another mod, survives.
function Power.syncVehicle(vehicleId, vehicle)
    if not Core.settings.PowerBinding or not vehicle then
        return
    end
    local assignment = vehicleId and Slots.find(vehicleId)
    if not assignment then
        return
    end

    local part, owner = Power.batteryPart(vehicle)
    if not part then
        -- No battery at all. Record it as flat so the room goes dark, and keep
        -- the debt: a battery installed later inherits it, which is right.
        assignment.batteryKnown = 0
        return
    end
    local battery = part:getInventoryItem()

    local charge = readCharge(battery)
    local owed = tonumber(assignment.fuelOwed) or 0
    local maxFuel = tonumber(assignment.generatorMaxFuel) or 0

    if owed > 0 and maxFuel > 0 then
        local factor = tonumber(Core.settings.PowerDrainFactor) or 100
        local used = (owed / maxFuel) * (factor / 100)
        local after = math.max(0, charge - used)
        writeCharge(battery, after)
        -- Without this the change never leaves the server. Same lesson as
        -- vehicle modData, except that here the per-part transmit exists and
        -- vanilla's own VehicleUtils.chargeBattery calls it. Sent on the
        -- vehicle that owns the part, which for a trailer is the one towing.
        owner:transmitPartUsedDelta(part)
        Core.debugLn(string.format("interior drew %.1f%% off the battery: %.0f%% -> %.0f%%",
            used * 100, charge * 100, after * 100))
        charge = after
        assignment.fuelOwed = 0
    end

    assignment.batteryKnown = charge
end

return Power
