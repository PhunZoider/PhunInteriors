if isServer() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/holders"
require "PhunInteriors/reservoir"
require "PhunInteriors/defaults"
require "PhunInteriors/client_main"
require "PhunInteriors/client_enter"
require "PhunInteriors/client_context"
require "PhunInteriors/client_reservoir"
require "PhunInteriors/client_guards"
require "PhunInteriors/client_tracker"
require "PhunInteriors/client_rooms"
require "PhunInteriors/client_admin"
local Core = PhunInteriors
local Client = Core.client
local Commands = require "PhunInteriors/client_commands"

-- The character setup ran for. A respawn creates a new one and the client's lua
-- does not reload, so without this the server never hears that the new
-- character exists and a safehouse respawn into a room is uncontained, with no
-- way out, until a relog.
local setupFor = nil

local function setup()
    Events.OnTick.Remove(setup)
    setupFor = getPlayer()
    Core.refreshSettings()
    -- Deferred so the vanilla classes we wrap are certain to be loaded.
    Client.installGuards()
    Client.installTracker()
    Client.installRemovalNotice()
    -- On a dedicated server the registry lives server side, but the client
    -- needs it too for menu decisions, so open registration here as well. In
    -- single player both this and server_events run, and the guard inside
    -- openRegistration is what stops every set registering twice.
    Core.openRegistration()
    triggerEvent(Core.events.OnReady, Core)
    Core.dispatch(Core.commands.playerSetup, {})
end

Events.OnTick.Add(setup)

-- A tick after the event, for the connection to be the new character's, and
-- carrying where they are. The server's copy of a new character's position
-- cannot be relied on this early: a respawn into a room found nothing, silently,
-- with the spawn point sitting in the server's own log (2026-11-01).
local function reportRespawn()
    Events.OnTick.Remove(reportRespawn)
    local player = getPlayer()
    if not player then
        return
    end
    Core.logLn(string.format("respawned at %s,%s,%s; telling the server", tostring(player:getX()),
        tostring(player:getY()), tostring(player:getZ())))
    Core.dispatch(Core.commands.playerSetup, {
        respawned = true,
        x = player:getX(),
        y = player:getY(),
        z = player:getZ()
    })
end

-- Only after setup, and only for a character it did not run for, so the first
-- creation at load never sends playerSetup twice.
Events.OnCreatePlayer.Add(function(playerIndex, player)
    if not setupFor or not player or player:getPlayerNum() ~= 0 or player == setupFor then
        return
    end
    setupFor = player
    -- Forget the dead character's room. The server's state reply says whether
    -- the new one is in one.
    Client.inside = false
    Client.noExit = false
    Events.OnTick.Remove(reportRespawn)
    Events.OnTick.Add(reportRespawn)
end)

Events.OnServerCommand.Add(function(module, command, arguments)
    if module == Core.name and Commands[command] then
        Commands[command](arguments or {})
    end
end)
