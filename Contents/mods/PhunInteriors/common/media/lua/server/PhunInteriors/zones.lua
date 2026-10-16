if isClient() then
    return
end
local Core = PhunInteriors
local Zones = {}
Core.modules.zones = Zones

-- ---------------------------------------------------------------------------
-- Puts back the map's power and water zones when the save has lost them.
--
-- The rooms are off the mains only because objects.lua paints NoPowerOrWater
-- over the block. A dedicated server and single player both register those
-- zones from objects.lua and THEN load the save's map_zone.bin over the top
-- (IsoWorld.init: OnLoadMapZones, IsoMetaGrid.load, load("map_zone.bin"),
-- processZones, OnLoadedMapZones), and the saved list wins. So a world created
-- before a zone existed never gets it: reported on a server that predated cell
-- 92,46, whose clients read the zone and whose server did not. A client skips
-- the save load entirely, which is why it always looks fine there.
--
-- The same happens when this mod is added to an existing world, and when
-- another map's objects.lua throws and vanilla's doMapZones stops before it
-- reaches ours. Either way the symptom is rooms on the mains until the grid
-- shuts off, and the generator binding invisible for weeks.
--
-- Our own file is the source, read the way metazoneHandler.lua reads it, so
-- the geometry is stated once and a re-cut map is followed with no edit here.
-- Only rectangle types that take no properties are healed: registerZone with
-- seven arguments is what vanilla uses for exactly those.
-- ---------------------------------------------------------------------------

Zones.file = "media/maps/phuninteriors/objects.lua"

Zones.HEALS = {
    NoPower = true,
    NoWater = true,
    NoPowerOrWater = true
}

-- The healable rectangles in our objects.lua, copied out. Leaves the `objects`
-- global as it found it, since vanilla's loader and other mods use the same
-- name. Nil and a reason when the file is missing or throws.
function Zones.read()
    if fileExists and not fileExists(Zones.file) then
        return nil, "no " .. Zones.file
    end
    local saved = objects
    objects = {}
    local ok, err = pcall(reloadLuaFile, Zones.file)
    local loaded = objects
    objects = saved
    if not ok then
        return nil, tostring(err)
    end
    local list = {}
    for _, v in ipairs(type(loaded) == "table" and loaded or {}) do
        if type(v) == "table" and Zones.HEALS[v.type] and v.geometry == nil and tonumber(v.x) and tonumber(v.y) and
            tonumber(v.width) and tonumber(v.height) then
            table.insert(list, {
                name = tostring(v.name or v.type),
                type = v.type,
                x = math.floor(tonumber(v.x)),
                y = math.floor(tonumber(v.y)),
                z = math.floor(tonumber(v.z) or 0),
                width = math.floor(tonumber(v.width)),
                height = math.floor(tonumber(v.height))
            })
        end
    end
    return list
end

local function present(metaGrid, z)
    return metaGrid:getZoneWithBoundsAndType(z.x, z.y, z.z, z.width, z.height, z.type) ~= nil
end

local function describe(z)
    return string.format("%s %d,%d,%d %dx%d", z.type, z.x, z.y, z.z, z.width, z.height)
end

-- Registers whichever of `list` the meta grid does not hold. Returns how many
-- were already there, how many were put back, and the ones it could not put
-- back. Asks again after registering, because registerZone refuses a zone it
-- finds suspicious (too big, or past the loaded cells) by logging and
-- returning the zone anyway, so its return value proves nothing.
function Zones.heal(list)
    local world = getWorld()
    local metaGrid = world:getMetaGrid()
    local had, healed, failed = 0, 0, {}
    for _, z in ipairs(list) do
        if present(metaGrid, z) then
            had = had + 1
        else
            pcall(function()
                world:registerZone(z.name, z.type, z.x, z.y, z.z, z.width, z.height)
            end)
            if present(metaGrid, z) then
                healed = healed + 1
            else
                table.insert(failed, describe(z))
            end
        end
    end
    return had, healed, failed
end

-- OnLoadedMapZones. Silent when nothing was missing.
function Zones.check()
    local list, err = Zones.read()
    if not list then
        Core.logLn("zones: could not read " .. Zones.file .. ": " .. tostring(err))
        return
    end
    local had, healed, failed = Zones.heal(list)
    if healed > 0 then
        Core.logLn(string.format("zones: this save was missing %d of %d power/water zone(s) from %s, " ..
                                     "registered them again", healed, #list, Zones.file))
    end
    for _, line in ipairs(failed) do
        Core.logLn("zones: could not register " .. line .. ", rooms under it stay on the mains")
    end
    Core.debugLn(string.format("zones: %d present, %d healed, %d failed", had, healed, #failed))
end

return Zones
