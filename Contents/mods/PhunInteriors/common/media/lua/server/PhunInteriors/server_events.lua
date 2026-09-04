if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
require "PhunInteriors/bounds"
require "PhunInteriors/defaults"
local Core = PhunInteriors
local Commands = require "PhunInteriors/server_commands"
local Slots = require "PhunInteriors/slots"
local Scrub = require "PhunInteriors/scrub"
local Manifest = require "PhunInteriors/manifest"
local Leash = require "PhunInteriors/leash"
local Admin = require "PhunInteriors/admin"
local Harden = require "PhunInteriors/harden"
local Author = require "PhunInteriors/author"

local started = false

local function start()
    if started then
        return
    end
    started = true

    Core.data = ModData.getOrCreate(Core.consts.modDataKey)
    Core.refreshSettings()

    -- registers the stock room sets and vehicle classes, and gives other mods
    -- their chance to register alongside them
    triggerEvent(Core.events.OnReady, Core)

    -- Adopt whatever already exists rather than judging it. Without this,
    -- installing on a live server with a 14 day lease expires every room at
    -- once on day one.
    Slots.adoptBaseline()

    Admin.registerChatCommands()

    Core.logLn("ready. " .. tostring(Core.settings.LeaseDays) .. " day leases, weight factor " ..
        tostring(Core.settings.WeightFactor) .. "%")
end

Events.OnInitGlobalModData.Add(start)
Events.OnServerStarted.Add(start)

Events.OnClientCommand.Add(function(module, command, player, arguments)
    if module == Core.name and Commands[command] then
        Commands[command](player, arguments or {})
    end
end)

-- Containment and the exit tile share this one handler.
Events.OnTick.Add(function()
    Leash.tick()
end)

-- Work the quarantine queue. Needs loaded chunks, so it retries rather than
-- assuming. There is no manifest retry here any more: blueprints are either
-- shipped with the room set or captured on first lease, and neither is
-- something a timer can help with.
Events.EveryTenMinutes.Add(function()
    Scrub.processQueue(2)
end)

Events.EveryOneMinute.Add(function()
    Harden.sweepFire()
end)

Events.EveryDays.Add(function()
    Slots.sweepLeases()
end)

-- A player who disconnects inside a room keeps their lease but loses their
-- occupancy; playerSetup rebuilds it when they come back.
Events.OnDisconnect.Add(function(player)
    local key = Core.playerKey(player)
    if key and Core.occupants[key] then
        Core.debugLn(tostring(key) .. " disconnected while inside, keeping the lease")
        Core.occupants[key] = nil
    end
end)

-- Keep the mass delta honest when a vehicle is destroyed: release the lease so
-- the slot recycles rather than leaking the way the reference mod does.
Events.OnVehicleDestroyed = Events.OnVehicleDestroyed or nil
if Events.OnVehicleDestroyed then
    Events.OnVehicleDestroyed.Add(function(vehicle)
        local vehicleId = Core.vehicleId(vehicle, false)
        if not vehicleId then
            return
        end
        -- anyone still inside comes out first
        for key, occupancy in pairs(Core.occupants) do
            if occupancy.vehicleId == vehicleId then
                local player = Core.tools.getPlayerByUsername(key)
                if player then
                    require("PhunInteriors/transit").leave(player, "breach")
                end
            end
        end
        Slots.release(vehicleId, "vehicle destroyed")
    end)
end
