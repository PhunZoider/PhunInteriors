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

-- Client.inside is otherwise only ever set by a teleport, and a player who
-- reconnects inside a room never receives one: the server rebuilds their
-- occupancy from the lease, but the client came up believing it is outside.
-- The exit tile still worked, so this only ever cost the context menu
-- option, which is the affordance people actually look for.
Commands[Core.commands.state] = function(arguments)
    Client.inside = arguments and arguments.inside and true or false
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
