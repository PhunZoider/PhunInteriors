-- Compatibility: PhunZones2. The zone half.
--
-- The interior block is a zone of its own in PhunZones, and it is declared
-- here rather than in PhunZones' data.lua because the geometry is ours: the
-- block has been carved from a rectangle into an L once already, and a copy
-- in another repo is a copy that drifts. PhunTaxi does the same for its Taxi
-- Garage.
--
-- `isVoid` is what makes the zone read as somewhere else. PhunZones' client
-- shows a void zone as the last zone the server pushed for that player
-- (`rvZone`), which is how Project RV Interior shows the town the RV is
-- parked in rather than a black box. The pushing is server/PhunInteriors/
-- phunzones.lua; this only has to say that our block is a void.
--
-- A soft hook. With PhunZones absent this does nothing, and the rooms are
-- still unpowered and zombie free by their own map (Known gaps #0 in
-- CLAUDE.md), so what the zone adds is removal of anything that gets realised
-- in there anyway, and a title that is not "Kentucky".
--
-- Added at load, not on an event, for PhunTaxi's reason: PhunZones builds its
-- lookup from this table on OnServerStarted and on the client's first tick,
-- and a zone added after that sits unused until the next rebuild. "PhunZones/
-- data" is a bare `return { ... }` with no requires of its own, so reaching it
-- first from here is safe, and require hands PhunZones the same table.
require "PhunInteriors/core"
local Core = PhunInteriors

-- PhunZones' key for the block. Kept as it was when PhunZones shipped it, so
-- an admin override written against that key still lands.
local ZONE_KEY = "PhunInteriors"

local state = {
    active = false,
    zoneKey = ZONE_KEY
}
Core.compat.phunzones = state

local function phunZonesActive()
    local mods = getActivatedMods()
    return mods:contains("phunzones2") or mods:contains("phunzones2test")
end

if phunZonesActive() then
    local ok, zones = pcall(require, "PhunZones/data")
    if ok and type(zones) == "table" then
        zones[ZONE_KEY] = {
            title = "Interior",
            difficulty = 0,
            -- Above every implicitly ordered zone. PhunZones' RV void starts
            -- at x=22500 and covers most of the block.
            order = 1000,
            zeds = "remove",
            -- Shown as the zone the holder is in. See the header.
            isVoid = true,
            -- Cells 87,46 to 91,48, then 89,49 to 91,49: the L that is left
            -- after 87,49 went to PhunTaxi and 88,49 to PhunRooms. PhunZones'
            -- rects are inclusive at both ends, unlike the half open
            -- NoPowerOrWater zones in objects.lua, so each ends on x255/y255.
            points = {{22272, 11776, 23551, 12543}, {22784, 12544, 23551, 12799}}
        }
        state.active = true
    else
        Core.logLn("PhunZones2 is active but PhunZones/data did not load; no interior zone registered")
    end
end

return state
