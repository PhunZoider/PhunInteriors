if isServer() then
    return
end
require "PhunInteriors/client_main"
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local Client = Core.client
local Commands = {}

Commands[Core.commands.teleport] = function(arguments)
    Client.teleport(arguments)
end

-- Client.inside is otherwise only ever set by a teleport, and a player who
-- reconnects inside a room never receives one: the server rebuilds their
-- occupancy from the lease, but the client came up believing it is outside.
-- Walking out still worked, so this only ever cost the context menu option,
-- which is the affordance people actually look for.
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

    -- The log is the right place for these when the console asked, and the
    -- wrong place when somebody clicked a button and is looking at a window.
    -- Only the first line: these are written to be read as a paragraph in a
    -- log and the window has one line to say it in.
    local shell = Core.ui.shell and Core.ui.shell.current()
    if shell and arguments.result[1] then
        shell:notice(tostring(arguments.result[1]))
    end
end

-- A fresh picture of the registry.
--
-- Stored in one place and ANNOUNCED, rather than handed to whoever asked.
-- Three tabs and any number of open forms read it, and a payload delivered
-- only to the caller is how two views of one registry come to disagree -- the
-- room list showing a room as customised while the form beside it still holds
-- the shipped values.
Commands[Core.commands.roomsResult] = function(arguments)
    Core.ui.state.receive(arguments)
end

-- One room's slots, answering the fetch the Slots tab makes when a room is
-- selected. Separate from the list above because 960 slot records riding on
-- every refresh is most of a payload that nothing draws.
Commands[Core.commands.roomSlotsResult] = function(arguments)
    Core.ui.state.receiveDetail(arguments)
end

return Commands
