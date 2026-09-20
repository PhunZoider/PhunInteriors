if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
require "PhunInteriors/bounds"
require "PhunInteriors/holders"
require "PhunInteriors/reservoir"
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
local Removal = require "PhunInteriors/removal"
local Store = require "PhunInteriors/store"

local started = false

local function start()
    if started then
        return
    end
    started = true

    Core.data = ModData.getOrCreate(Core.consts.modDataKey)
    Core.refreshSettings()

    -- Rooms, then the vehicles that may use them, then everything else.
    -- Registering on any of the three works, because the indexes rebuild on
    -- first read; the order exists so that by the time vehicles are declaring
    -- links, every room set that is ever going to exist already does.
    --
    -- This runs on OnInitGlobalModData, which is long after every mod's lua
    -- files have been loaded -- so by the time it fires, every listener that
    -- is ever going to be attached already is.
    Core.openRegistration()

    -- What the admin editor changed, put back on over the shipped registry.
    --
    -- Between registration and OnReady, so a third party listening on OnReady
    -- sees the rooms as they will actually be rather than as they shipped. A
    -- room that registers LATER than this -- which is allowed, and is what the
    -- author notes tell third parties to do -- picks its own patch up inside
    -- registerRoom, so this is the bulk of the work rather than all of it.
    Store.load()

    triggerEvent(Core.events.OnReady, Core)

    -- Adopt whatever already exists rather than judging it. Without this,
    -- upgrading a live server could make every lease reclaimable at once.
    Slots.adoptBaseline()

    Admin.registerChatCommands()

    -- Wraps the vanilla action that scraps a vehicle, so the room of a vehicle
    -- that is gone for good is released rather than left until its lease runs
    -- out. See removal.lua for why that cannot be an event.
    Removal.install()

    -- Counts only. What is *missing* is deliberately not reported here: a mod
    -- is free to register from any vanilla hook, which can land after this
    -- line, and a boot time warning about a set that turns up a moment later
    -- is worse than no warning at all. Slots.acquire says it at the point of
    -- failure instead, where the answer is always current.
    Core.logLn("ready. " .. Core.describeRegistry())
    Core.logLn("rooms kept " .. tostring(Core.settings.RoomProtectedDays) .. " day(s) unused, weight factor " ..
        tostring(Core.settings.WeightFactor) .. "%")
end

Events.OnInitGlobalModData.Add(start)
Events.OnServerStarted.Add(start)

Events.OnClientCommand.Add(function(module, command, player, arguments)
    if module == Core.name and Commands[command] then
        Commands[command](player, arguments or {})
    end
end)

-- Containment, the way out, and the cab tile all share this one handler.
--
-- Weight used to poll here too, waiting for a departing player's vehicle to
-- come back into a loaded chunk. It is applied on their arrival report now,
-- which is the same moment without the timer.
Events.OnTick.Add(function()
    Leash.tick()
    -- One nil compare unless an admin has just removed a leased vehicle.
    Removal.tick()
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

-- There is no daily lease sweep. Leases used to expire on a clock, which threw
-- away a tenant's belongings whether or not anybody wanted the room; now a room
-- is only reclaimed at the moment a vehicle needs it and every room is full.
-- See Slots.acquire.

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

-- Nor is there an OnVehicleDestroyed handler, for the same kind of reason:
-- B42 declares no such event. There was one, guarded by a test for the event,
-- and it skipped itself silently. A removed vehicle's room is released by
-- removal.lua, which hooks the calls that remove one.
