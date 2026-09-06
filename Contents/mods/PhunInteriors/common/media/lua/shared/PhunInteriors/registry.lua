require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Room sets and vehicle classes are registered, not hard coded. Other mods do
-- exactly what defaults.lua does: hook OnReady and call these two functions.
-- Ids are namespaced author.name so two mods cannot collide.
-- ---------------------------------------------------------------------------

local function warn(str)
    Core.logLn("registry: " .. str)
end

--- Register a grid of identical off-grid slots.
-- @param id namespaced id, eg "phun.van"
-- @param def origin/pitch/count/size/spawn/exits/power/label
function Core.registerRoomSet(id, def)
    if type(id) ~= "string" or not def then
        warn("registerRoomSet needs an id and a definition")
        return
    end
    if not def.origin or not def.size then
        warn("room set '" .. id .. "' needs origin and size")
        return
    end

    if Core.roomSets[id] then
        warn("room set '" .. id .. "' is being redefined")
    end

    Core.roomSets[id] = {
        id = id,
        label = def.label or id,
        origin = {
            x = def.origin.x,
            y = def.origin.y,
            z = def.origin.z or 0
        },
        pitch = {
            x = (def.pitch and def.pitch.x) or 0,
            y = (def.pitch and def.pitch.y) or 0
        },
        count = def.count or 32,
        size = {
            w = def.size.w,
            h = def.size.h
        },
        spawn = {
            x = (def.spawn and def.spawn.x) or 1,
            y = (def.spawn and def.spawn.y) or 1
        },
        -- squares that, when stood on, put the player back at the vehicle.
        -- relative to the slot origin.
        exits = def.exits or {},
        -- where the generator lives. z is relative, and deliberately outside
        -- the leash, so it is reached through a panel and never on foot.
        power = def.power or {x = 0, y = 0, z = 1},
        -- What the fitted-out room weighs before anybody puts anything in it.
        -- The blueprint's own fixtures are deliberately not charged for -- they
        -- are always there, so billing them per item would just be a flat tax
        -- with a confusing derivation. This says the same thing once, as a
        -- number the author picked.
        baseWeight = tonumber(def.baseWeight) or 0,
        source = def.source or "unknown"
    }

    Core.debugLn("registered room set " .. id .. " (" .. Core.roomSets[id].count .. " slots)")
    return Core.roomSets[id]
end

--- Bind vehicles to a room set.
-- @param id namespaced id, eg "phun.van"
-- @param def roomSet, scripts, match, requires
function Core.registerVehicleClass(id, def)
    if type(id) ~= "string" or not def or not def.roomSet then
        warn("registerVehicleClass needs an id and a roomSet")
        return
    end

    Core.vehicleClasses[id] = {
        id = id,
        roomSet = def.roomSet,
        scripts = def.scripts or {},
        match = def.match,
        requires = def.requires or {},
        source = def.source or "unknown"
    }

    -- A script belongs to exactly one class. Later registrations win, but we
    -- say so rather than silently taking over someone else's vehicle.
    for _, script in ipairs(Core.vehicleClasses[id].scripts) do
        local key = string.lower(script)
        local existing = Core.scriptLookup[key]
        if existing and existing ~= id then
            warn("'" .. script .. "' moved from class '" .. existing .. "' to '" .. id .. "'")
        end
        Core.scriptLookup[key] = id
    end

    Core.debugLn("registered vehicle class " .. id .. " -> " .. def.roomSet)
    return Core.vehicleClasses[id]
end

--- Register the shipped blueprints for a room set.
--
-- Called by a file that PhunInteriors.author generated. This is the third of
-- the three calls a map author needs and the only one they could not
-- plausibly hand write, which is what makes generating all three the right
-- shape rather than shipping a blueprint exporter on its own.
--
-- One palette is shared across every slot in the set: rooms in a strip are
-- variations on a theme and share nearly all their sprites.
function Core.registerBlueprints(id, def)
    if type(id) ~= "string" or not def or not def.slots then
        warn("registerBlueprints needs an id and a slots table")
        return
    end

    local count = 0
    for _ in pairs(def.slots) do
        count = count + 1
    end

    Core.blueprints[id] = {
        version = def.version or 2,
        palette = def.palette or {},
        slots = def.slots
    }

    Core.debugLn("registered " .. count .. " shipped blueprint(s) for " .. id)
    return Core.blueprints[id]
end

--- One slot's shipped blueprint, in the shape Manifest.spritesAt expects.
--
-- The stored form shares a palette across the set, so this hands back a view
-- that borrows it rather than copying: spritesAt only ever reads.
function Core.shippedBlueprint(id, index)
    local shipped = Core.blueprints[id]
    if not shipped then
        return nil
    end
    local squares = shipped.slots[index] or shipped.slots[tostring(index)]
    if not squares then
        return nil
    end
    return {
        version = shipped.version,
        palette = shipped.palette,
        squares = squares
    }
end

--- Let admins bind extra scripts to an existing class without any code.
-- Sandbox option is a comma separated list of script names.
function Core.applySandboxScriptOverrides()
    for classId, class in pairs(Core.vehicleClasses) do
        local optionName = "Scripts_" .. string.gsub(classId, "%.", "_")
        local raw = Core.getOption(optionName, "")
        if raw and raw ~= "" then
            for entry in string.gmatch(raw, "([^,]+)") do
                local script = entry:match("^%s*(.-)%s*$")
                if script ~= "" then
                    Core.scriptLookup[string.lower(script)] = classId
                    Core.debugLn("sandbox bound '" .. script .. "' to " .. classId)
                end
            end
        end
    end
end

--- Which class, if any, owns this vehicle. Script lookup first because it is
--- a hash hit; matchers only run when that misses.
function Core.classForVehicle(vehicle)
    if not vehicle or not vehicle.getScript then
        return nil
    end
    local script = vehicle:getScript()
    if not script then
        return nil
    end

    local full = string.lower(tostring(script:getFullName()))
    local classId = Core.scriptLookup[full]
    if classId then
        return Core.vehicleClasses[classId]
    end

    for _, class in pairs(Core.vehicleClasses) do
        if class.match then
            local ok, matched = pcall(class.match, vehicle)
            if ok and matched then
                return class
            end
        end
    end

    return nil
end

--- Does this vehicle satisfy its class's entry requirements?
--- Returns false plus a translation key when it does not.
--- Is this vehicle moving?
--
-- isStopped() rather than a speed threshold of our own. A stationary vehicle
-- under tow reports a non-zero getCurrentSpeedKmHour -- confirmed in game: a
-- parked towed van refused entry from outside while telling the player it was
-- moving. The coupling never quite settles, so any epsilon we pick is a guess
-- about physics jitter.
--
-- isStopped is the engine's own answer and it is what vanilla gates vehicle
-- interaction on, in ISExitVehicle:isValid and ISVehicleMenu.lua:185. If it is
-- good enough to decide whether you may climb out, it is good enough here.
function Core.vehicleIsMoving(vehicle)
    if not vehicle then
        return false
    end
    return not vehicle:isStopped()
end

--- Is this player actually the one driving this vehicle?
--
-- Not just isDriver. Sitting in seat 0 of something under tow is not driving
-- it -- the vehicle in front is -- which is exactly why vanilla has a separate
-- getDriverRegardlessOfTow. Being told you cannot leave the wheel of a van
-- somebody else is towing is the kind of rule that reads as a bug.
function Core.isAtTheWheel(vehicle, player)
    if not vehicle or not player then
        return false
    end
    return vehicle:isDriver(player) and vehicle:getVehicleTowedBy() == nil
end

--- Can this player move from where they are into the interior right now?
-- Returns true, or false plus a translation key.
--
-- Shared, and there is exactly one copy on purpose. The server enforces this
-- in Transit.canEnter; the client checks the same function in beginEnter so a
-- refusal is instant rather than arriving after a fifteen second action. Two
-- copies of a rule like this drift, which is the mistake the reference mod
-- made with its whole SP path.
--
-- Moving between a seat and the interior is an internal move, and allowed --
-- the mirror of leaving the interior into a free seat while under way. The two
-- things that are not allowed are catching a vehicle you are not aboard, and
-- walking away from the wheel of one you are driving.
function Core.vehicleMotionAllows(vehicle, player)
    if not Core.vehicleIsMoving(vehicle) then
        return true
    end
    if player:getVehicle() ~= vehicle then
        -- The speed is logged because this is the refusal that went wrong
        -- once already: a parked towed van reported enough movement to trip a
        -- fixed threshold, and the only symptom was a refusal that made no
        -- sense to the player standing next to a stationary vehicle.
        Core.debugLn(string.format("refused boarding: %s is not stopped (%.2f km/h)",
            tostring(vehicle:getScriptName()), vehicle:getCurrentSpeedKmHour()))
        return false, "IGUI_PhunInteriors_VehicleMovingBoard"
    end
    if Core.isAtTheWheel(vehicle, player) then
        return false, "IGUI_PhunInteriors_DrivingCannotEnter"
    end
    return true
end

function Core.vehicleAllows(vehicle, class)
    if not class or not class.requires then
        return true
    end

    if class.requires.trunk then
        local parts = vehicle:getPartCount() - 1
        local found = false
        for i = 0, parts do
            local part = vehicle:getPartByIndex(i)
            if part and part:getItemContainer() and part:getContainerCapacity() > 0 then
                found = true
                break
            end
        end
        if not found then
            return false, "IGUI_PhunInteriors_NoTrunk"
        end
    end

    if class.requires.battery then
        if vehicle:getBatteryCharge() <= 0 then
            return false, "IGUI_PhunInteriors_NoBattery"
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Slot geometry. The leash, the exit test and the scrub all read from here, so
-- there is exactly one definition of where a slot actually is.
-- ---------------------------------------------------------------------------

function Core.slotOrigin(set, index)
    return {
        x = set.origin.x + (set.pitch.x * index),
        y = set.origin.y + (set.pitch.y * index),
        z = set.origin.z
    }
end

function Core.slotBounds(set, index)
    local o = Core.slotOrigin(set, index)
    return {
        x1 = o.x,
        y1 = o.y,
        x2 = o.x + set.size.w - 1,
        y2 = o.y + set.size.h - 1,
        z = o.z
    }
end

function Core.slotSpawn(set, index)
    local o = Core.slotOrigin(set, index)
    return {
        x = o.x + set.spawn.x,
        y = o.y + set.spawn.y,
        z = o.z
    }
end

function Core.inBounds(bounds, x, y, z)
    if not bounds then
        return false
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    return z == bounds.z and x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2
end

--- Is this square one of the slot's exit tiles?
--- Where the generator lives in this slot.
--
-- set.power has been captured by the authoring tool, emitted into every
-- blueprint file and stored here since the beginning, and until now nothing
-- read it. Note the z is relative and normally 1, so the power square sits a
-- level above the floor -- which is why every sweep over a slot covers
-- bounds.z to bounds.z + 1.
function Core.slotPower(set, index)
    local o = Core.slotOrigin(set, index)
    local p = set.power or {x = 0, y = 0, z = 1}
    return {
        x = o.x + p.x,
        y = o.y + p.y,
        z = o.z + (p.z or 1)
    }
end

function Core.isExitSquare(set, index, x, y, z)
    local o = Core.slotOrigin(set, index)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if z ~= o.z then
        return false
    end
    for _, exit in ipairs(set.exits) do
        if x == o.x + exit.x and y == o.y + exit.y then
            return true
        end
    end
    return false
end

return Core
