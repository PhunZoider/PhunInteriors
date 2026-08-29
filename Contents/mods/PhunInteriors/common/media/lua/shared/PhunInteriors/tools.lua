require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Local utility surface.
--
-- These three were previously borrowed from PhunLib. PhunLib is deprecated and
-- this mod carries no hard dependency, so they are folded in here, matching
-- what PhunServer2 and PhunZones2 already do.
--
-- Keep this file to things that genuinely have no vanilla equivalent. It is
-- not a dumping ground.
-- ---------------------------------------------------------------------------

local tools = {}
Core.tools = tools

-- Wrapper for getOnlinePlayers that normalises SP, coop host and dedicated.
-- In SP there is one player and getOnlinePlayers is not the answer; on a
-- client we only ever care about the local split-screen players.
function tools.onlinePlayers(all)

    local onlinePlayers

    if Core.isLocal then
        onlinePlayers = ArrayList.new()
        local p = getPlayer()
        if p then
            onlinePlayers:add(p)
        end
    elseif all ~= false and isClient() then
        onlinePlayers = ArrayList.new()
        for i = 0, getOnlinePlayers():size() - 1 do
            local player = getOnlinePlayers():get(i)
            if player:isLocalPlayer() then
                onlinePlayers:add(player)
            end
        end
    else
        onlinePlayers = getOnlinePlayers()
    end

    return onlinePlayers
end

-- PZ's Lua sandbox does not expose next(), so an emptiness test has to go
-- through pairs. Same gap PhunMart2 hit in restockTypes.
function tools.isEmpty(t)
    if not t then
        return true
    end
    for _ in pairs(t) do
        return false
    end
    return true
end

-- Case insensitive by default. Returns nil when the player is not online,
-- which every caller here treats as "skip", never as an error.
function tools.getPlayerByUsername(name, caseSensitive)
    if not name then
        return nil
    end
    local online = tools.onlinePlayers()
    if not online then
        return nil
    end
    local text = caseSensitive and name or string.lower(name)
    for i = 0, online:size() - 1 do
        local player = online:get(i)
        if player then
            local username = player:getUsername()
            if username then
                if (caseSensitive and username == name) or
                    (not caseSensitive and string.lower(username) == text) then
                    return player
                end
            end
        end
    end
    return nil
end

-- Admin test for a *specific* player, because this is called server side to
-- vet an incoming command. The family's tools.isAdmin() asks about the local
-- machine, which is the wrong question on a dedicated server.
--
-- In single player there is no access level to speak of and it is the host's
-- own world, so the local player is allowed.
function tools.isAdmin(player)
    if Core.isLocal then
        return true
    end
    if player and player.getAccessLevel then
        local level = player:getAccessLevel()
        return level == "Admin" or level == "Moderator" or level == "admin" or level == "moderator"
    end
    return (isAdmin and isAdmin()) or (isDebugEnabled and isDebugEnabled()) or false
end

return tools
