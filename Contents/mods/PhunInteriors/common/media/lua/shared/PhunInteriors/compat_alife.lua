-- Compatibility: Project A-Life NPCs (mod id ProjectALifeNPCs).
--
-- A-Life's NPCs are zombie bodies: an IsoZombie the mod drives as a person.
-- To our zombie sweep in transit.lua each one is a zombie, so a player
-- standing beside a friendly NPC was refused entry with "zombies too close"
-- (reported 2026-10-20), and the exit shove would push one about.
--
-- The test is PhunZones2's Core.isALife, copied rather than called so this
-- works without PhunZones installed: the server stamps ProjectALifeOwned (or
-- ProjectALifeActor) into the body's modData, and an MP client only learns it
-- from A-Life's own presentation message, so the animation variable it sets
-- is checked as well. Every caller here is server side, where the modData
-- flag is authoritative.
--
-- Never run in game, and the author does not have the mod installed: the
-- flag names are what PhunZones reads, not something read out of A-Life.
local M = {}

local active

function M.active()
    if active == nil then
        local mods = getActivatedMods and getActivatedMods()
        active = mods ~= nil and mods:contains("ProjectALifeNPCs") or false
    end
    return active
end

--- True when this zombie is really an A-Life NPC.
function M.isNpc(zed)
    if not M.active() then
        return false
    end
    local data = zed.getModData and zed:getModData()
    if data and (data.ProjectALifeOwned == true or data.ProjectALifeActor == true) then
        return true
    end
    return zed.GetVariable ~= nil and zed:GetVariable("ALifeActor") == "true"
end

return M
