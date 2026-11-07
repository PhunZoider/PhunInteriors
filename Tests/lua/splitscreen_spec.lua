-- Two players on one client.
--
-- getPlayer() answers IsoPlayer.instance, which the engine moves around within
-- a frame, so everywhere the mod meant "this character" and asked getPlayer()
-- it acted on a bystander, with no error anywhere. Reported on 2026-11-02: player
-- 1 walked out of a door and stayed in the room, stepping outside took both
-- players out, and entering dragged the other one in.
--
-- So getPlayer here always answers with somebody nobody asked about. Anything
-- still reading it acts on that player, and the checks below see it move.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

local report = stubs.reporter()
local check = report.check

local function fakePlayer(name, num, id)
    local p = {
        name = name,
        x = 100,
        y = 100,
        moves = 0
    }
    function p.getUsername()
        return name
    end
    function p.getPlayerNum()
        return num
    end
    function p.getOnlineID()
        return id
    end
    function p.getX()
        return p.x
    end
    function p.getY()
        return p.y
    end
    function p.getZ()
        return 0
    end
    function p.getVehicle()
        return nil
    end
    function p.teleportTo(_, x, y)
        p.x, p.y = x, y
        p.moves = p.moves + 1
    end
    return p
end

local one = fakePlayer("pat", 0, 10)
local two = fakePlayer("ada", 1, 11)
local locals = {
    [0] = one,
    [1] = two
}
local active = 2

function getNumActivePlayers()
    return active
end
function getSpecificPlayer(i)
    return locals[i]
end
function getPlayer()
    return two
end
function getPlayerContextMenu()
    return nil
end
function getCell()
    return {
        setDrag = function()
        end,
        getGridSquare = function()
            return {}
        end
    }
end
Vector3f = {
    new = function()
        return {}
    end
}
ArrayList = {
    new = function()
        local list = {items = {}}
        function list:add(item)
            table.insert(self.items, item)
        end
        function list:size()
            return #self.items
        end
        function list:get(i)
            return self.items[i + 1]
        end
        return list
    end
}
package.preload["PhunInteriors/ui/state"] = function()
    return {}
end

-- -------------------------------------------------------------------------
-- The server's side of the question: who is there.
-- -------------------------------------------------------------------------

Core.isLocal = true
local everyone = Core.tools.onlinePlayers()
check("the leash is shown every local player", everyone:size(), 2)
check("player 1 is among them", everyone:get(0), one)
check("player 2 is among them", everyone:get(1), two)

-- Both default to the same name when nothing has set one.
local bobOne, bobTwo = fakePlayer("Bob", 0, -1), fakePlayer("Bob", 1, -1)
check("two local players never share a key", Core.playerKey(bobOne) ~= Core.playerKey(bobTwo), true)
check("player 1's key is the bare name", Core.playerKey(bobOne), "Bob")

Core.isLocal = false
check("in multiplayer the key survives a reconnect", Core.playerKey(bobTwo), "Bob")
Core.isLocal = true

-- -------------------------------------------------------------------------
-- Single player: both directions are direct calls.
-- -------------------------------------------------------------------------

local serverCommands = require "PhunInteriors/server_commands"
local asked = nil
serverCommands.splitTest = function(player)
    asked = player
end
Core.dispatch("splitTest", {}, one)
check("a named player is the one who asked", asked, one)
Core.dispatch("splitTest", {})
check("the admin tools still fall back to getPlayer", asked, two)

local Client = (require "PhunInteriors/client_main")
local clientCommands = require "PhunInteriors/client_commands"

-- -------------------------------------------------------------------------
-- A teleport moves who it was for, on the call and on every held tick. The hold
-- is what dragged the bystander along.
-- -------------------------------------------------------------------------

local function runTicks(count)
    for _ = 1, count do
        for _, fn in ipairs(Events.OnTick.fns) do
            fn()
        end
    end
end

-- Not there yet: the square is nil, so the hold goes on re-asserting.
function getCell()
    return {
        setDrag = function()
        end,
        getGridSquare = function()
            return nil
        end
    }
end

Core.respond(one, Core.commands.teleport, {
    x = 500,
    y = 600,
    z = 0,
    inside = true
})
runTicks(3)
check("the teleport moves player 1", one.x, 500.5)
check("the hold keeps moving player 1", one.moves, 4)
check("player 2 stays put", two.x, 100)
check("player 2 was never touched", two.moves, 0)
check("player 1 is inside", Client.isInside(one), true)
check("player 2 is not", Client.isInside(two), false)

-- Both in transit at once, to different places.
Core.respond(two, Core.commands.teleport, {
    x = 700,
    y = 800,
    z = 0,
    inside = true,
    noExit = true
})
runTicks(2)
check("player 2 lands at their own destination", two.x, 700.5)
check("player 1 is still held at theirs", one.x, 500.5)
check("no way out is per player", Client.hasNoExit(two), true)
check("and player 1 still has one", Client.hasNoExit(one), false)

-- One finishing must not end the other's hold.
one.x, one.y = 500, 600
function getCell()
    return {
        setDrag = function()
        end,
        getGridSquare = function(_, x)
            return x == 500 and {} or nil
        end
    }
end
local twoMoves = two.moves
runTicks(2)
check("player 1 arriving leaves player 2 held", two.moves > twoMoves, true)
local oneMoves = one.moves
runTicks(1)
check("player 1 is no longer held", one.moves, oneMoves)

-- Leaving: only the one who left.
Core.respond(one, Core.commands.teleport, {
    x = 900,
    y = 900,
    z = 0,
    inside = false
})
check("leaving clears player 1", Client.isInside(one), false)
check("and leaves player 2 inside", Client.isInside(two), true)

-- The reply to a reconnect is per player too.
clientCommands[Core.commands.state]({
    inside = true,
    noExit = false
}, one)
check("the state reply reaches its player", Client.isInside(one), true)
clientCommands[Core.commands.state]({
    inside = false
}, two)
check("and does not cross over", Client.isInside(one), true)
check("the other is cleared", Client.isInside(two), false)

-- -------------------------------------------------------------------------
-- Over the wire: a command has to name its player in both directions.
-- -------------------------------------------------------------------------

Core.isLocal = false
local sent = nil
function sendClientCommand(...)
    sent = {
        n = select("#", ...),
        ...
    }
end
Core.dispatch(Core.commands.leave, {}, two)
check("a named player uses the four argument form", sent.n, 4)
check("and it carries that player", sent[1], two)
Core.dispatch(Core.commands.rooms, {})
check("the admin tools stay on three", sent.n, 3)

local toldArgs = nil
function sendServerCommand(player, module, command, args)
    toldArgs = args
end
Core.respond(two, Core.commands.notify, {
    text = "x"
})
check("a reply is addressed to its player", toldArgs.forPlayer, 11)
Core.respond(one, Core.commands.state)
check("even one that had no arguments", toldArgs.forPlayer, 10)

check("the address finds player 2", Client.recipient({
    forPlayer = 11
}), two)
check("and player 1", Client.recipient({
    forPlayer = 10
}), one)
check("somebody else's address finds nobody", Client.recipient({
    forPlayer = 99
}), nil)
active = 1
check("alone on the client there is only one answer", Client.recipient({
    forPlayer = 99
}), one)

os.exit(report.finish("splitscreen") == 0 and 0 or 1)
