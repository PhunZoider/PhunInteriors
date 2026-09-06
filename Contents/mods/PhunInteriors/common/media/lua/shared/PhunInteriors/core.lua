PhunInteriors = {
    name = "PhunInteriors",
    consts = {
        -- key we hang our own state off, on both vehicles and the global ModData
        modDataKey = "PhunInteriors",
        vehicleIdKey = "PhunInteriors_id",
        massDeltaKey = "PhunInteriors_massDelta"
    },
    data = {},
    commands = {
        playerSetup = "playerSetup",
        enter = "enter",
        leave = "leave",
        teleport = "teleport",
        notify = "notify",
        admin = "admin",
        adminResult = "adminResult",
        author = "author",
        -- server -> client, so a reconnecting player learns they are inside
        state = "state",
        -- client -> server: "the vehicle with this id just moved, go and look
        -- at it". Deliberately carries no coordinates; see Transit.notePosition.
        updatePosition = "updatePosition",
        -- client -> server: "I have landed back outside, and this is the id of
        -- the vehicle I found there". Closes the exit handshake.
        arrived = "arrived"
    },
    events = {
        OnReady = "PhunInteriorsOnReady",
        OnEnter = "PhunInteriorsOnEnter",
        OnExit = "PhunInteriorsOnExit"
    },
    -- registry, populated by registry.lua and by other mods on OnReady
    roomSets = {},
    vehicleClasses = {},
    -- shipped blueprints, keyed by room set id, registered by generated files
    blueprints = {},
    scriptLookup = {},
    -- server side only: username -> occupancy record
    occupants = {},
    settings = {},
    ui = {},
    modules = {}
}

local Core = PhunInteriors

Core.isLocal = not isClient() and not isServer() and not isCoopHost()

for _, event in pairs(Core.events) do
    if not Events[event] then
        LuaEventManager.AddEvent(event)
    end
end

-- Every constraint this mod imposes is a switch, and the defaults are the
-- balanced ones. An admin who wants the old power fantasy turns them off.
Core.defaults = {
    Debug = false,
    WeightFactor = 50,
    ExitTax = true,
    ExitTaxGrowth = 2,
    EntryDelay = 15,
    EntryBlockedByZombies = true,
    EntryZombieRadius = 4,
    LeaseDays = 14,
    LeaseWarningDays = 2,
    ScrubKeepsLoot = false,
    HardenShell = true,
    BreachEjects = true,
    AdminNoClipExempt = true,
    PowerBinding = true,
    PowerDrainFactor = 100,
}

function Core.getOption(name, default)
    local opt = getSandboxOptions():getOptionByName(Core.name .. "." .. name)
    local val = opt and opt:getValue()
    if val == nil then
        return default
    end
    return val
end

function Core.refreshSettings()
    for name, default in pairs(Core.defaults) do
        Core.settings[name] = Core.getOption(name, default)
    end
    return Core.settings
end

function Core.debugLn(str)
    if Core.settings.Debug then
        print("[" .. Core.name .. "] " .. tostring(str))
    end
end

function Core.logLn(str)
    print("[" .. Core.name .. "] " .. tostring(str))
end

-- Client -> server. In single player there is no round trip, so call the
-- handler directly. This is what keeps SP and MP on one code path.
function Core.dispatch(command, args)
    if Core.isLocal then
        local handlers = require "PhunInteriors/server_commands"
        local handler = handlers[command]
        if handler then
            handler(getPlayer(), args or {})
        end
    else
        sendClientCommand(Core.name, command, args or {})
    end
end

-- Server -> client, same deal in reverse.
function Core.respond(player, command, args)
    if Core.isLocal then
        local handlers = require "PhunInteriors/client_commands"
        local handler = handlers[command]
        if handler then
            handler(args or {})
        else
            Core.logLn("no local client handler for '" .. tostring(command) .. "'")
        end
    else
        sendServerCommand(player, Core.name, command, args or {})
    end
end

function Core.playerKey(player)
    if not player then
        return nil
    end
    return player:getUsername() or tostring(player:getOnlineID())
end

-- Vehicles get a stable id of our own. getId() is not durable across restarts
-- in every configuration, and we need something we can key a lease on.
function Core.vehicleId(vehicle, create)
    if not vehicle then
        return nil
    end
    local vmd = vehicle:getModData()
    if not vmd[Core.consts.vehicleIdKey] and create then
        vmd[Core.consts.vehicleIdKey] = tostring(getRandomUUID())
    end
    return vmd[Core.consts.vehicleIdKey]
end

--- Find a loaded vehicle by our own durable id, near a position.
--
-- getVehicleById cannot do this: BaseVehicle:getId() is assigned when a
-- vehicle enters the world, and one that unloads and reloads comes back with
-- a different id. The modData UUID is written into the save, so it is the
-- only handle that survives, and a vehicle whose chunk just streamed in is
-- exactly the case both sides care about -- the client re-seating a player,
-- the server charging a vehicle for what its interior holds.
function Core.vehicleNear(x, y, z, vehicleId, radius)
    local cell = getCell()
    if not cell or not vehicleId then
        return nil
    end
    radius = radius or 3
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            local vehicle = square and square:getVehicleContainer()
            if vehicle and Core.vehicleId(vehicle, false) == vehicleId then
                return vehicle
            end
        end
    end
    return nil
end

--- The vehicle nearest a position, whatever it is.
--
-- Used client side on the way out of a room, where the question is not "which
-- vehicle is mine" but "which vehicle is at the spot the server just sent me
-- to". The server has already resolved identity -- it holds the lease and it
-- read the position itself -- so the client only has to do the geometry, and
-- it reports the id it found back up so the server can verify before acting
-- on it.
--
-- This is why nothing here needs the modData UUID. Vehicle level modData is
-- never transmitted to clients (BaseVehicle carries no sync path for it, only
-- transmitPartModData), so a client side UUID match can never succeed on a
-- dedicated server.
function Core.nearestVehicle(x, y, z, radius)
    local cell = getCell()
    if not cell then
        return nil
    end
    radius = radius or 3
    local best, bestDistance = nil, nil
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            local vehicle = square and square:getVehicleContainer()
            if vehicle then
                local distance = (dx * dx) + (dy * dy)
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = vehicle, distance
                end
            end
        end
    end
    return best
end

function Core.now()
    return getGameTime():getWorldAgeHours()
end

Core.refreshSettings()

Events.EveryTenMinutes.Add(function()
    Core.refreshSettings()
end)

return Core
