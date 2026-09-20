if isClient() then
    return
end
require "PhunInteriors/registry"
-- Core.isOurSpace, for the world object half of the ledger. Every boot path
-- happens to load this first anyway; the require is here so that a reordering
-- cannot quietly take it away.
require "PhunInteriors/bounds"
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
-- Position is fixed data: the room's 'generator' offset, from the authoring
-- tool, emitted into the blueprint. It does not move. What can change is
-- whether the generator still
-- exists -- it caught fire, it blew up, a scrub left an inert copy -- and a
-- room whose lights never come back because of that is worse than one that
-- quietly repairs itself.
function Power.ensureGenerator(roomId, index)
    local room = Core.rooms[roomId]
    -- slotPower is nil for a room with no 'generator', which is a room that is
    -- meant to have no power -- a tent -- rather than one whose position we
    -- failed to find. There is no default position to fall back on, which is
    -- the whole point: a wrong one fails silently and self-heals into looking
    -- deliberate.
    local at = room and Core.slotPower(room, index)
    if not at then
        return nil, false
    end

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
            tostring(roomId), tostring(index)))
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
        tostring(roomId), tostring(index), at.x, at.y, at.z))
    return generator, true
end

--- What the battery would read if the outstanding debt were settled now.
--
-- The room cannot see the battery, so this is how it knows whether there is
-- still anything to draw on. Without it, a tenant sitting inside long enough
-- to empty a full tank would watch the lights die while their van sat outside
-- with a charged battery.
--- What the outstanding debt comes to, as a fraction of whatever is paying.
--
-- Pulled out of projectedCharge because two callers have to agree about it
-- exactly. This one predicts the moment the room goes dark; Power.syncObject
-- takes the fuel out of the generator that makes it happen. Written twice they
-- would drift, and the symptom is the worst kind available: a room that
-- darkens at a level the tank never reaches, or one that never darkens at all.
--
-- A fraction rather than litres, because the other end of this is sometimes a
-- battery, and 0..1 is the only quantity both ends can express.
local function owedCharge(assignment)
    local owed = tonumber(assignment.fuelOwed) or 0
    local maxFuel = tonumber(assignment.generatorMaxFuel) or 0
    if owed <= 0 or maxFuel <= 0 then
        return 0
    end
    local factor = tonumber(Core.settings.PowerDrainFactor) or 100
    return (owed / maxFuel) * (factor / 100)
end
Power.owedCharge = owedCharge

local function projectedCharge(assignment)
    return (tonumber(assignment.batteryKnown) or 0) - owedCharge(assignment)
end
Power.projectedCharge = projectedCharge

--- Read the generator, bank what it burned, and top it up if there is charge.
--
-- Called while the room is loaded, which is the only time any of this is
-- readable. Safe to call repeatedly: it measures a difference, so a second
-- call a moment later banks nothing.
function Power.syncRoom(roomId, index, vehicleId)
    if not Core.settings.PowerBinding then
        return
    end
    local room = Core.rooms[roomId]
    if not room or not room.generator then
        return
    end
    local assignment = vehicleId and Slots.find(vehicleId)
    if not assignment then
        return
    end

    local generator, created = Power.ensureGenerator(roomId, index)
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
    --
    -- Skipped entirely for a selfPowered room. There is no other end to this
    -- ledger, so banking a debt nothing will ever settle would send the
    -- projected charge negative and darken a room that is meant never to go
    -- out -- which is the same fault the admin port hit, and why it resets
    -- fuelOwed on every visit.
    if not room.selfPowered and not created and assignment.fuelLast then
        local burnt = math.max(0, assignment.fuelLast - now)
        if burnt > 0 then
            assignment.fuelOwed = (tonumber(assignment.fuelOwed) or 0) + burnt
            Core.debugLn(string.format("%s#%s burned %.1f fuel; %.1f owed",
                tostring(roomId), tostring(index), burnt, assignment.fuelOwed))
        end
    end

    -- Fill it if there is anything left to draw on. Full, not proportional:
    -- the battery is the limiting resource, the tank is only a buffer.
    --
    -- A selfPowered room always has something to draw on, by definition. Note
    -- it still needs the generator above: haveElectricity() is only ever a real
    -- activated IsoGenerator in the chunk, so the flag buys free fuel and not
    -- free power.
    local fuel = now
    if room.selfPowered or projectedCharge(assignment) > 0 then
        fuel = maxFuel
    else
        fuel = 0
    end
    if room.selfPowered then
        assignment.fuelOwed = 0
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

-- ---------------------------------------------------------------------------
-- The other end of the ledger, for a holder that is not a vehicle.
--
-- A tent has no battery, so entering one used to declare the battery full and
-- clear the debt -- which made the room a free, permanent mains supply, the
-- one thing the power binding exists to prevent. It was honest scaffolding at
-- the time, and this is the piece it was standing in for.
--
-- What pays instead is a real generator the player parked beside the tent, and
-- WHICH generator is deliberately not a question of ours. haveElectricity() on
-- the tent's own square is the same test that decides whether a fridge stood
-- next to it would run, so a tent is powered exactly when its own square is,
-- and a server that turns AllowExteriorGenerator off is saying that a
-- generator outdoors powers nothing. This says the same thing without having
-- to be told, and without a field on the room that could disagree with vanilla.
--
-- Generator to generator the two ends are the same quantity, which is what
-- makes this half simpler than the vehicle's: PowerDrainFactor exists only
-- because litres and battery percentage are not, and at its default of 100 a
-- litre burned in the room is a litre out of the tank beside the tent. The
-- conversion is owedCharge, shared with the projection, so the level at which
-- the room predicts it will go dark is the level the tank actually reaches.
-- ---------------------------------------------------------------------------

-- The perimeter of a square ring, one entry per offset. Cached because the
-- search below asks for the same twenty or so rings on every call, and
-- rebuilding those tables per visit would be the only allocation on this path.
local ringCache = {}
local function ringOffsets(ring)
    if ringCache[ring] then
        return ringCache[ring]
    end
    local out = {}
    if ring == 0 then
        out = {{0, 0}}
    else
        for d = -ring, ring do
            table.insert(out, {d, -ring})
            table.insert(out, {d, ring})
        end
        for d = -ring + 1, ring - 1 do
            table.insert(out, {-ring, d})
            table.insert(out, {ring, d})
        end
    end
    ringCache[ring] = out
    return out
end

--- The nearest activated generator in range of this square, or nil.
--
-- Rings outward rather than sweeping a box, for two reasons. A tent with a
-- generator two tiles away is answered in twenty squares rather than eleven
-- thousand; and where a player has several, the one they parked closest is the
-- one billed, which is the answer they would give if asked.
--
-- getGenerator() is vanilla's own accessor and reads the square's special
-- objects, so it is one list lookup rather than a walk of everything standing
-- there. Activated matters: only an activated generator registers its position
-- with the chunk, so only an activated one is powering anything.
local function generatorNear(square)
    local cell = getCell()
    if not cell then
        return nil
    end
    -- Vanilla's own numbers, because vanilla's own test is what said there was
    -- a generator here at all. GeneratorTileRange is a Euclidean radius.
    local radius = tonumber(SandboxVars and SandboxVars.GeneratorTileRange) or 20
    local levels = tonumber(SandboxVars and SandboxVars.GeneratorVerticalPowerRange) or 3
    local x0, y0, z0 = square:getX(), square:getY(), square:getZ()

    -- This level first, then one up, then one down, and outward. The vertical
    -- range is symmetrical and the tent's own floor is overwhelmingly where it
    -- will be.
    local zs = {0}
    for d = 1, levels do
        table.insert(zs, d)
        table.insert(zs, -d)
    end

    for ring = 0, radius do
        for _, offset in ipairs(ringOffsets(ring)) do
            local dx, dy = offset[1], offset[2]
            if (dx * dx) + (dy * dy) <= radius * radius then
                for _, dz in ipairs(zs) do
                    local candidate = cell:getGridSquare(x0 + dx, y0 + dy, z0 + dz)
                    local generator = candidate and candidate:getGenerator()
                    if generator and generator:isActivated() then
                        return generator
                    end
                end
            end
        end
    end
    return nil
end

--- Settle the debt against the generator powering a world object holder.
--
-- The twin of Power.syncVehicle, called at the same two moments and for the
-- same reason: the holder is loaded while the tenant is standing on it, which
-- is entering and landing back, and it is loaded at no other time.
--
-- `at` is where the holder is, which for a tent is its grid anchor. Nothing
-- about the object's identity is needed here -- this bills whatever generator
-- is powering that spot, exactly as the room is lit by whatever generator is
-- in range of it.
function Power.syncObject(leaseKey, at)
    if not Core.settings.PowerBinding or not at then
        return
    end
    local assignment = leaseKey and Slots.find(leaseKey)
    if not assignment then
        return
    end

    -- A tent pitched INSIDE one of our own rooms would otherwise be billed to
    -- that room's own generator, which we refuel for nothing: the interior
    -- would be paying itself. Refused rather than solved, because a holder
    -- standing in a room is a question about nested interiors and not one
    -- about power.
    if Core.isOurSpace(at.x, at.y, at.z or 0) then
        assignment.batteryKnown = 0
        Core.debugLn("power: " .. tostring(leaseKey) ..
            " is standing inside one of our own rooms; it powers nothing")
        return
    end

    local cell = getCell()
    local square = cell and cell:getGridSquare(at.x, at.y, at.z or 0)
    if not square then
        -- Not loaded, so nothing here is readable. Leave the ledger alone: the
        -- debt is still owed and the last reading is still the last reading.
        return
    end

    -- Vanilla's answer, and the only gate on the walk below. A tent nobody has
    -- parked a generator at is answered in one call and never rings at all.
    if not square:haveElectricity() then
        -- Flat, so the room goes dark, and the debt is KEPT: a generator
        -- wheeled up later inherits it, which is the same rule the vehicle
        -- half applies to a battery installed later.
        assignment.batteryKnown = 0
        return
    end

    local generator = generatorNear(square)
    if not generator then
        -- The square says it has power and nothing in range of it is a
        -- generator, which should not be possible and is worth saying rather
        -- than quietly reading as a flat battery.
        assignment.batteryKnown = 0
        Core.logLn("power: " .. tostring(leaseKey) ..
            " has electricity but no generator was found in range; treating it as dark")
        return
    end

    local maxFuel = tonumber(generator:getMaxFuel()) or 0
    local fuel = tonumber(generator:getFuel()) or 0

    local owed = owedCharge(assignment)
    if owed > 0 and maxFuel > 0 then
        -- owedCharge is a fraction of a tank, so this is the same quantity the
        -- projection subtracted, said in this generator's litres.
        local used = owed * maxFuel
        local after = math.max(0, fuel - used)
        generator:setFuel(after)
        -- Without this the change never leaves the server. Vanilla's own
        -- ISAddFuel:complete() pairs setFuel with sync(), and this is the same
        -- write. Deliberately NOT setActivated: the generator belongs to the
        -- player, and running it dry is theirs to notice rather than ours to
        -- switch off.
        generator:sync()
        Core.debugLn(string.format("interior drew %.1f fuel off the generator: %.1f -> %.1f",
            used, fuel, after))
        fuel = after
        assignment.fuelOwed = 0
    end

    assignment.batteryKnown = (maxFuel > 0) and (fuel / maxFuel) or 0
end

return Power
