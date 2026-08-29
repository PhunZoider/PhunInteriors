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
local Core = PhunInteriors
local Commands = require "PhunInteriors/client_commands"

local function setup()
    Events.OnTick.Remove(setup)
    Core.refreshSettings()
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
