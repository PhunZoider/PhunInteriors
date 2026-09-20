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

local function setup()
    Events.OnTick.Remove(setup)
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

Events.OnServerCommand.Add(function(module, command, arguments)
    if module == Core.name and Commands[command] then
        Commands[command](arguments or {})
    end
end)
