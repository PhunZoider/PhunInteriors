-- AntiCheat.teleportPunished: whether a transit would get this player kicked.
--
-- The checks that matter are the two failure directions. Refusing an exempt
-- admin makes the mod untestable by the people who test it; letting an
-- ordinary player through on a Kick or Ban server gets them thrown off it.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

local AntiCheat = require "PhunInteriors/anticheat"
local report = stubs.reporter()
local check = report.check

-- The server side of the world this module asks about.
local policy = "2"
local debug = false
local serverSide = true
function isServer()
    return serverSide
end
function isDebugEnabled()
    return debug
end
function getServerOptions()
    return {
        getOption = function(_, name)
            if name == "AntiCheatSpeed" then
                return policy
            end
        end
    }
end
Capability = {
    TeleportToPlayer = "TeleportToPlayer",
    TeleportToCoordinates = "TeleportToCoordinates",
    TeleportPlayerToAnotherPlayer = "TeleportPlayerToAnotherPlayer",
    UseFastMoveCheat = "UseFastMoveCheat",
    CantBeKickedByAnticheat = "CantBeKickedByAnticheat",
    ToggleNoclipHimself = "ToggleNoclipHimself"
}

local function playerWith(...)
    local caps = {}
    for _, c in ipairs({...}) do
        caps[c] = true
    end
    return {
        getRole = function()
            return {
                hasCapability = function(_, cap)
                    return caps[cap] == true
                end
            }
        end
    }
end

local wasLocal = Core.isLocal
Core.isLocal = false

local plain = playerWith()
local admin = playerWith("TeleportToCoordinates")

policy = "2"
check("kick policy punishes a plain player", AntiCheat.teleportPunished(plain), "kick")
check("kick policy spares a teleporting admin", AntiCheat.teleportPunished(admin), nil)
check("the blanket exemption counts", AntiCheat.teleportPunished(playerWith("CantBeKickedByAnticheat")), nil)
check("fast move counts", AntiCheat.teleportPunished(playerWith("UseFastMoveCheat")), nil)
check("an unrelated capability does not", AntiCheat.teleportPunished(playerWith("ToggleNoclipHimself")), "kick")

policy = "1"
check("ban policy says ban", AntiCheat.teleportPunished(plain), "ban")

policy = "3"
check("log policy punishes nobody", AntiCheat.teleportPunished(plain), nil)
policy = "4"
check("disabled punishes nobody", AntiCheat.teleportPunished(plain), nil)
policy = "nonsense"
check("an unreadable policy refuses nobody", AntiCheat.teleportPunished(plain), nil)

policy = "2"
debug = true
check("a -debug server never kicks", AntiCheat.teleportPunished(plain), nil)
debug = false

check("a player whose role cannot be read is not exempt", AntiCheat.teleportPunished({
    getRole = function()
        error("no role")
    end
}), "kick")
check("no player, no answer", AntiCheat.teleportPunished(nil), nil)

serverSide = false
check("off a server there is no anti-cheat", AntiCheat.teleportPunished(plain), nil)
serverSide = true

Core.isLocal = true
check("single player is never punished", AntiCheat.teleportPunished(plain), nil)
Core.isLocal = wasLocal

os.exit(report.finish("anticheat") == 0 and 0 or 1)
