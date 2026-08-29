if isServer() then
    return
end
require "PhunInteriors/client_main"
local Core = PhunInteriors
local Client = Core.client
local Commands = {}

Commands[Core.commands.teleport] = function(arguments)
    Client.teleport(arguments)
end

Commands[Core.commands.notify] = function(arguments)
    Client.notify(arguments)
end

Commands[Core.commands.adminResult] = function(arguments)
    if not arguments or not arguments.result then
        return
    end
    for _, line in ipairs(arguments.result) do
        print("[" .. Core.name .. "] " .. tostring(line))
    end
end

return Commands
