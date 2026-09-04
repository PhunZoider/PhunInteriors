PhunInteriors = {
    name = "PhunInteriors",
    consts = {
        -- key we hang our own state off, on both vehicles and the global ModData
        modDataKey = "PhunInteriors",
        -- slot index reserved as the pristine copy the manifest is scanned from.
        -- it is never handed out to a vehicle.
        goldenSlot = 0,
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
        author = "author"
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

function Core.now()
    return getGameTime():getWorldAgeHours()
end

Core.refreshSettings()

Events.EveryTenMinutes.Add(function()
    Core.refreshSettings()
end)

return Core
