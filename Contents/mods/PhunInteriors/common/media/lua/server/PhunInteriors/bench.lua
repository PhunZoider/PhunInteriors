if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Transit = require "PhunInteriors/transit"

-- ---------------------------------------------------------------------------
-- The vehicle bench: spawn a vehicle beside an admin, clear the last one away.
--
-- It exists for binding a vehicle pack, where the loop is spawn, look at it,
-- pick a room, walk in, and go again a hundred times. The window is
-- ui/bench.lua; this is the half that touches the world, and it is server side
-- because both halves of it are: vanilla's own remove command calls
-- permanentlyRemove() from VehicleCommands on the server, and /addvehicle
-- spawns from AddVehicleCommand on the server.
--
-- The spawn is addVehicleDebug plus what AddVehicleCommand does after it, read
-- out of the bytecode: repair(), and the driver's door unlocked. The key is
-- different on purpose. The command puts it in the ignition, and the lock check
-- (Core.vehicleLockAllows) asks whether the player CARRIES it, so it goes in
-- the admin's inventory the way vanilla's getKey command does it.
-- ---------------------------------------------------------------------------

local Bench = {}

-- Where the vehicle goes, from the admin's square. East and pointing north, so
-- it runs alongside rather than across them; three squares puts a semi trailer
-- clear of the admin and still well inside the clearing radius, so the next
-- press takes it away again.
local OFFSET_X = 3

local function vehiclesNear(player, radius)
    local out = {}
    local cell = getCell()
    if not cell then
        return out
    end
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local own = player:getVehicle()
    -- Collected first and removed after, because removing from the Set the
    -- iterator walks is a ConcurrentModificationException waiting to happen.
    pcall(function()
        local it = cell:getVehicles():iterator()
        while it:hasNext() do
            local vehicle = it:next()
            if vehicle and vehicle ~= own and not vehicle:isRemovedFromWorld() and
                math.abs(vehicle:getZ() - z) < 1.5 then
                local dx, dy = vehicle:getX() - x, vehicle:getY() - y
                if dx * dx + dy * dy <= radius * radius then
                    table.insert(out, vehicle)
                end
            end
        end
    end)
    return out
end

local function scriptName(vehicle)
    local script = vehicle:getScript()
    return script and script:getFullName() or "a vehicle"
end

--- Remove every vehicle within `radius` of the player, except one they sit in.
---
--- A leased vehicle has its room released first, through Removal.vacate, which
--- is what the admin remove cheat ends in. That matters more here than
--- anywhere: this is a loop that leases a room on every pass, and leaving each
--- one leased to a vehicle that no longer exists would fill the pool with
--- nobody. A vehicle whose tenant cannot be put out is left standing.
function Bench.clear(player, radius)
    radius = tonumber(radius) or 5
    local Removal = require "PhunInteriors/removal"
    local removed, kept = {}, {}
    for _, vehicle in ipairs(vehiclesNear(player, radius)) do
        local name = scriptName(vehicle)
        local vehicleId = Core.vehicleId(vehicle, false)
        local free = true
        if vehicleId and Slots.find(vehicleId) then
            Transit.notePosition(vehicle:getId())
            free = Removal.vacate(vehicleId, "removed by the vehicle bench")
        end
        if free then
            vehicle:permanentlyRemove()
            table.insert(removed, name)
        else
            table.insert(kept, name)
        end
    end
    return removed, kept
end

--- Spawn a vehicle by script name beside the player.
---
--- Returns the vehicle, or nil and why.
function Bench.spawn(player, script)
    if not script or script == "" then
        return nil, "no script named"
    end
    if not getScriptManager():getVehicle(script) then
        return nil, "no vehicle script called " .. script .. " is loaded"
    end
    local x = math.floor(player:getX()) + OFFSET_X
    local y = math.floor(player:getY())
    local z = math.floor(player:getZ())
    local square = getCell():getGridSquare(x, y, z)
    if not square then
        return nil, "the square beside you is not loaded"
    end

    local vehicle = addVehicleDebug(script, IsoDirections.N, nil, square)
    if not vehicle then
        -- addVehicleDebug returns nil when IsoChunk.doSpawnedVehiclesInInvalidPosition
        -- refuses, which is something solid in the way.
        return nil, "the game refused to place it there; move to open ground"
    end

    vehicle:repair()
    local door = vehicle:getPassengerDoor(0)
    if door and door:getDoor() then
        door:getDoor():setLocked(false)
    end
    local key = vehicle:createVehicleKey()
    if key then
        player:getInventory():AddItem(key)
        sendAddItemToContainer(player:getInventory(), key)
    end
    return vehicle
end

--- Clear, then spawn. One action rather than two so the window's Next button is
--- one round trip and the old vehicle cannot outlive the new one's arrival.
function Bench.next(player, script, radius)
    local removed, kept = Bench.clear(player, radius)
    local lines = {}
    local vehicle, why = Bench.spawn(player, script)
    if vehicle then
        table.insert(lines, "spawned " .. script)
    else
        table.insert(lines, "could not spawn " .. tostring(script) .. ": " .. tostring(why))
    end
    if #removed > 0 then
        table.insert(lines, "removed " .. table.concat(removed, ", "))
    end
    if #kept > 0 then
        table.insert(lines, "left " .. table.concat(kept, ", ") .. ": somebody is inside its room")
    end
    return lines
end

return Bench
