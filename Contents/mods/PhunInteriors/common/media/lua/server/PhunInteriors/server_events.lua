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
local Weight = require "PhunInteriors/weight"
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
--
-- Weight used to poll here too, waiting for a departing player's vehicle to
-- come back into a loaded chunk. It is applied on their arrival report now,
-- which is the same moment without the timer.
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
    -- Exit paperwork for a player who never reported landing, eg one who
    -- disconnected mid teleport.
    require("PhunInteriors/transit").sweepArrivals()
end)

Events.EveryDays.Add(function()
    Slots.sweepLeases()
end)

-- There is deliberately no disconnect handler.
--
-- This used to hook Events.OnDisconnect to drop the occupancy of a player who
-- logged out inside a room. That never once fired: OnDisconnect is a *client*
-- event meaning "you were disconnected", it takes no player argument, and
-- vanilla uses it only in ConnectToServer.lua and ISMPEditAccount.lua to
-- report a failed connection. B42 has no server side "a player left" event at
-- all -- LuaEventManager declares none.
--
-- Nothing is lost by that. Core.occupants is in memory, so a player who
-- disconnects inside keeps their record, and playerSetup finds it still there
-- when they return and skips the rebuild. The leash only looks at players who
-- are online, so a record for somebody absent costs nothing. A server restart
-- clears the lot, and Transit.recover puts back whoever is still standing
-- inside a leased room.

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
