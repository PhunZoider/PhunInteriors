if isServer() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/defaults"
require "PhunInteriors/client_main"
require "PhunInteriors/client_enter"
require "PhunInteriors/client_context"
require "PhunInteriors/client_guards"
require "PhunInteriors/client_tracker"
local Core = PhunInteriors
local Client = Core.client
local Commands = require "PhunInteriors/client_commands"

local function setup()
    Events.OnTick.Remove(setup)
    Core.refreshSettings()
    -- Deferred so the vanilla classes we wrap are certain to be loaded.
    Client.installGuards()
    Client.installTracker()
    -- On a dedicated server the registry lives server side, but the client
    -- needs it too for menu decisions, so fire our ready event here as well.
    triggerEvent(Core.events.OnReady, Core)
    Core.dispatch(Core.commands.playerSetup, {})
end

Events.OnTick.Add(setup)

Events.OnServerCommand.Add(function(module, command, arguments)
    if module == Core.name and Commands[command] then
        Commands[command](arguments or {})
    end
end)
