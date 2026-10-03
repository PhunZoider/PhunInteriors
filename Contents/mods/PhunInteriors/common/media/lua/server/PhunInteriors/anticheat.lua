if isClient() then
    return
end
local Core = PhunInteriors
local AntiCheat = {}
Core.modules.anticheat = AntiCheat

-- ---------------------------------------------------------------------------
-- Whether the server's speed anti-cheat will punish a teleport.
--
-- Every way in and out of a room is a teleport, and B42 gives a mod no way to
-- make one the server will accept. AntiCheatSpeed works the speed out server
-- side from the positions the client reports, once a second
-- (NetworkCharacterAI$SpeedChecker), and a jump across the map reads as
-- thousands of tiles a second. The only thing that excuses one is
-- SpeedChecker.reset(), which is private and reached only from
-- GameServer.sendTeleport -- not exposed to Lua -- and from the admin teleport
-- packets, every one of which demands a teleport capability.
--
-- So a stock server (AntiCheatSpeed = 2, Kick) kicks an ordinary player after
-- a transit or two: the speed stays stored until the next sample, every
-- reliable update packet in that second is a strike, four strikes is the kick
-- and a strike takes 150 seconds to wear off. At 1 it BANS them.
--
-- AntiCheatSpeed.validate passes a connection whose role carries any of the
-- capabilities below, and AntiCheat.act never kicks while the server runs with
-- -debug. Both are mirrored here, so an admin testing a room is not refused
-- for a rule the engine does not apply to them.
-- ---------------------------------------------------------------------------

-- AntiCheat$Policy: 1 Ban, 2 Kick, 3 Log, 4 Disabled.
local PUNISHES = {
    [1] = "ban",
    [2] = "kick"
}

-- What AntiCheatSpeed.validate skips the check for, plus the blanket exemption
-- AntiCheat.act tests before acting on any of them.
local EXEMPT = {"TeleportToPlayer", "TeleportToCoordinates", "TeleportPlayerToAnotherPlayer", "UseFastMoveCheat",
                "CantBeKickedByAnticheat"}

--- The server's AntiCheatSpeed policy as a number, or nil off a server.
--
-- getOption rather than getOptionByName():getValue(), because it answers a
-- string for every option type and vanilla's MapSpawnSelect reads it that way.
function AntiCheat.speedPolicy()
    if not isServer() or not getServerOptions then
        return nil
    end
    local ok, value = pcall(function()
        return getServerOptions():getOption("AntiCheatSpeed")
    end)
    return ok and tonumber(value) or nil
end

--- "ban" or "kick" when the server punishes a fast move at all, else nil.
--
-- Not per player: this is what the boot warning reports.
function AntiCheat.punishment()
    if Core.isLocal then
        return nil
    end
    if isDebugEnabled and isDebugEnabled() then
        return nil
    end
    return PUNISHES[AntiCheat.speedPolicy() or 0]
end

--- Whether this player's role is excused from the speed check.
function AntiCheat.isExempt(player)
    local ok, role = pcall(function()
        return player:getRole()
    end)
    if not ok or not role or not Capability then
        return false
    end
    for _, name in ipairs(EXEMPT) do
        local cap = Capability[name]
        if cap then
            local has, yes = pcall(function()
                return role:hasCapability(cap)
            end)
            if has and yes then
                return true
            end
        end
    end
    return false
end

--- "ban" or "kick" when teleporting this player would get them punished.
--
-- Every entry path asks before it allocates anything, so a refused entry
-- leases nothing and renews nothing. Leaving is deliberately NOT gated: a
-- tenant who is inside already is better kicked than stranded, and with the
-- entries gated nobody but an exempt player gets inside to begin with.
function AntiCheat.teleportPunished(player)
    local punishment = AntiCheat.punishment()
    if not punishment or not player then
        return nil
    end
    if AntiCheat.isExempt(player) then
        return nil
    end
    return punishment
end

--- Log once at boot, loudly, if this server will punish tenants.
function AntiCheat.warnAtBoot()
    local punishment = AntiCheat.punishment()
    if not punishment then
        return
    end
    Core.logLn("WARNING: AntiCheatSpeed=" .. tostring(AntiCheat.speedPolicy()) .. " will " .. punishment ..
                   " any player who enters or leaves an interior, because every transit is a teleport and B42 gives" ..
                   " a mod no way to excuse one. Entry is refused for players without a teleport capability until" ..
                   " the server sets AntiCheatSpeed=3 (log) or 4 (disabled).")
end

return AntiCheat
