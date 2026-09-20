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

-- A copy nothing else holds a reference into.
--
-- The override layer needs one for a reason worth stating: it snapshots the
-- definition a room was registered with, so that reverting can rebuild from
-- it. A shallow copy would share `locations`, `spawn` and `requires` with the
-- live room, so the first edit would write through into the snapshot and the
-- "shipped" value an admin reverts to would be the edited one. That failure is
-- invisible -- revert appears to work and simply changes nothing.
--
-- Metatables are deliberately not carried. Everything copied here is plain
-- data out of a registry table or a decoded JSON document; a copy that kept a
-- metatable would be copying behaviour, which is not what any caller means.
function tools.deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = tools.deepCopy(item)
    end
    return out
end

-- Structural equality, used to decide whether an edit actually changed
-- anything. Saving an override identical to the shipped value is how a file
-- fills up with entries that do nothing and a room reads as "customised" when
-- it is stock, so the editor diffs against the snapshot and drops what matches.
function tools.deepEquals(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, item in pairs(a) do
        if not tools.deepEquals(item, b[key]) then
            return false
        end
    end
    -- Both directions: the loop above is satisfied by `a` being a subset of
    -- `b`, so a key present only in `b` would compare equal.
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
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
