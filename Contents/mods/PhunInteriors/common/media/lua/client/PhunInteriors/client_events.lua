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

-- The character setup ran for, by player number. A respawn creates a new one and
-- the client's lua does not reload, so without this the server never hears that
-- the new character exists and a safehouse respawn into a room is uncontained,
-- with no way out, until a relog. A second split screen player joining is the
-- same event with nobody before them.
local setupFor = {}
local setupDone = false

local function setup()
    Events.OnTick.Remove(setup)
    setupDone = true
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
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player then
            setupFor[i] = player
            Core.dispatch(Core.commands.playerSetup, {}, player)
        end
    end
end

Events.OnTick.Add(setup)

-- New characters the server has not heard about, by player number, each with
-- whether they replaced somebody.
local toReport = {}

-- A tick after the event, for the connection to be the new character's, and
-- carrying where they are. The server's copy of a new character's position
-- cannot be relied on this early: a respawn into a room found nothing, silently,
-- with the spawn point sitting in the server's own log (2026-11-01).
--
-- And not before the server knows them. A split screen player joining is -1
-- until the server answers their connect, and it drops a command from an index
-- it holds nobody at, so one sent now would never have arrived.
local function reportNewPlayers()
    local waiting = false
    for playerNum = 0, 3 do
        local report = toReport[playerNum]
        local player = report and getSpecificPlayer(playerNum)
        if report and player ~= report.player then
            toReport[playerNum] = nil
        elseif report and not Core.isLocal and player:getOnlineID() < 0 then
            waiting = true
        elseif report then
            toReport[playerNum] = nil
            if report.respawned then
                Core.logLn(string.format("respawned at %s,%s,%s; telling the server", tostring(player:getX()),
                    tostring(player:getY()), tostring(player:getZ())))
                Core.dispatch(Core.commands.playerSetup, {
                    respawned = true,
                    x = player:getX(),
                    y = player:getY(),
                    z = player:getZ()
                }, player)
            else
                Core.dispatch(Core.commands.playerSetup, {}, player)
            end
        end
    end
    if not waiting then
        Events.OnTick.Remove(reportNewPlayers)
    end
end

-- Only after setup, and only for a character it did not run for, so the first
-- creation at load never sends playerSetup twice.
Events.OnCreatePlayer.Add(function(playerIndex, player)
    if not setupDone or not player then
        return
    end
    local playerNum = player:getPlayerNum()
    if player == setupFor[playerNum] then
        return
    end
    toReport[playerNum] = {
        player = player,
        respawned = setupFor[playerNum] ~= nil
    }
    setupFor[playerNum] = player
    -- Forget the dead character's room. The server's state reply says whether
    -- the new one is in one.
    Client.setInside(player, false)
    Events.OnTick.Remove(reportNewPlayers)
    Events.OnTick.Add(reportNewPlayers)
end)

Events.OnServerCommand.Add(function(module, command, arguments)
    if module == Core.name and Commands[command] then
        arguments = arguments or {}
        Commands[command](arguments, Client.recipient(arguments))
    end
end)
