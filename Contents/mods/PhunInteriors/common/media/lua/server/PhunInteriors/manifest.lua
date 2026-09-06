if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = {}
Core.modules.manifest = Manifest

-- ---------------------------------------------------------------------------
-- What a fresh room looks like.
--
-- Blueprints are scanned, never hand authored. There are two kinds:
--
--   per slot   the truth for one room, scanned the first time that room is
--              leased. A slot that has never been leased has never been
--              modified, so it is pristine by definition.
--   per set    slot 0 of a room set, the golden slot, never leased. Now a
--              fallback for slots whose own capture never landed.
--
-- Per set capture alone homogenised the map: one blueprint applied to every
-- slot in the set, so the first scrub rewrote every room to look like slot 0
-- and any variety the map author built was destroyed one lease at a time. It
-- was also fragile in practice, because the golden slot is nowhere near where
-- players actually are and its chunk is usually not loaded.
--
-- Stored shape:
--
--   {
--     version = 2,
--     palette = {"sprite_a", "sprite_b", ...},   -- distinct names, 1 based
--     squares = {["dx,dy,dz"] = {1, 2, 2}},      -- indices into palette
--     objectCount = 17,
--     capturedAt = 1042.5
--   }
--
-- Measured on the borrowed van room: 29 objects from 11 distinct sprites, 379
-- bytes against 699 without the palette. So a few hundred blueprints is on the
-- order of 100KB. The palette halves that and costs nothing to keep, but size
-- was never the constraint it was assumed to be.
-- ---------------------------------------------------------------------------

local MANIFEST_VERSION = 2

-- How many leash ticks we keep trying a first lease capture before giving up
-- and falling back to a sibling room. Four a second, so this is ten seconds.
Manifest.CAPTURE_ATTEMPTS = 40

local function slotStore(roomSetId)
    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    Core.data.slotManifests = Core.data.slotManifests or {}
    Core.data.slotManifests[roomSetId] = Core.data.slotManifests[roomSetId] or {}
    return Core.data.slotManifests[roomSetId]
end

--- Objects that describe the room itself, as opposed to its contents.
--
-- The invariant is that a manifest holds exactly what a scrub removes, so this
-- and Scrub.clearSquare have to agree object for object. Floors are the case
-- that matters, and identifying one is not obvious: instanceof(o, "IsoFloor")
-- has zero uses anywhere in vanilla lua, and measured against a real room it
-- filtered nothing at all. Vanilla asks the square instead -- square:getFloor()
-- is how every build and debug tool in the game finds a floor -- so that is
-- what both sides use. Comparing object identity against it needs no class
-- introspection and cannot quietly stop working.
local function isStructural(object, floor)
    if not object then
        return false
    end
    if floor and object == floor then
        return false
    end
    if instanceof(object, "IsoWorldInventoryObject") then
        return false
    end
    if instanceof(object, "IsoMovingObject") then
        return false
    end
    return true
end

--- Read one slot into a per square list of palette indices.
--
-- Also counts the squares that were not there. An object count of zero is
-- ambiguous on its own -- an unloaded chunk and a room holding nothing but
-- floors look identical -- and that ambiguity cost a debugging session, so the
-- caller gets both numbers rather than having to guess which it hit.
local function scan(set, index)
    local bounds = Core.slotBounds(set, index)
    local origin = Core.slotOrigin(set, index)
    local squares = {}
    local palette = {}
    local seen = {}
    local total = 0
    local present = 0
    local missing = 0

    -- +1 on z so the power square on the roof is captured too
    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                if not square then
                    missing = missing + 1
                else
                    present = present + 1
                    local indices = {}
                    local floor = square:getFloor()
                    local objects = square:getObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if isStructural(object, floor) then
                            local sprite = object:getSprite()
                            local name = sprite and sprite:getName()
                            if name then
                                local id = seen[name]
                                if not id then
                                    table.insert(palette, name)
                                    id = #palette
                                    seen[name] = id
                                end
                                table.insert(indices, id)
                                total = total + 1
                            end
                        end
                    end
                    if #indices > 0 then
                        -- relative, so a blueprint can be applied to any slot
                        local key = (x - origin.x) .. "," .. (y - origin.y) .. "," .. (z - origin.z)
                        squares[key] = indices
                    end
                end
            end
        end
    end

    return {
        version = MANIFEST_VERSION,
        palette = palette,
        squares = squares,
        objectCount = total,
        capturedAt = Core.now()
    }, present, missing
end

--- Scan one slot, or nil if it cannot be read cleanly.
--
-- Public so the authoring tool can scan a room set that is not registered
-- yet: it takes the set definition rather than an id, and Core.slotBounds
-- only needs origin, pitch and size, so a half built definition works. The
-- reason for the failure comes back with it, because the author sweeping a
-- strip needs to know which slots they still have to walk to.
function Manifest.scanSlot(set, index)
    local captured, present, missing = scan(set, index)
    if missing > 0 then
        return nil, string.format("%d of %d squares not loaded", missing, present + missing)
    end
    if captured.objectCount == 0 then
        return nil, "loaded but nothing to capture"
    end
    return captured
end

--- Sprite names for one square, whichever format the manifest is in.
--
-- Version 1 stored names directly and may still be sitting in an existing
-- save, so it is read rather than migrated. A manifest is cheap to recapture
-- and a migration path that runs once is not worth carrying.
function Manifest.spritesAt(manifest, key)
    local entry = manifest and manifest.squares and manifest.squares[key]
    if not entry then
        return nil
    end
    if not manifest.palette then
        return entry
    end
    local names = {}
    for i = 1, #entry do
        local name = manifest.palette[entry[i]]
        if name then
            table.insert(names, name)
        end
    end
    return names
end

--- Roughly what a manifest weighs, in bytes of stored strings.
--
-- Not exact: PZ adds per entry serialisation overhead we cannot see from here.
-- The point is that both figures come from a real capture rather than a guess.
function Manifest.measure(manifest)
    if not manifest then
        return nil
    end
    local nameBytes, keyBytes, placements = 0, 0, 0
    local palette = manifest.palette or {}
    for _, name in ipairs(palette) do
        nameBytes = nameBytes + #name
    end
    for key, entry in pairs(manifest.squares or {}) do
        keyBytes = keyBytes + #key
        placements = placements + #entry
    end
    local averageName = nameBytes / math.max(1, #palette)
    return {
        distinct = #palette,
        placements = placements,
        -- an index costs a couple of bytes; a name would have cost its length
        withPalette = nameBytes + keyBytes + (placements * 2),
        withoutPalette = math.floor(keyBytes + (placements * averageName))
    }
end

local function describe(roomSetId, label, captured, size)
    return string.format(
        "captured %s for %s: %d objects, %d distinct sprites, ~%d bytes (~%d without the palette)",
        label, roomSetId, captured.objectCount, size.distinct, size.withPalette, size.withoutPalette)
end

--- Any blueprint we already hold for this room set.
--
-- The last resort when a slot has neither a shipped blueprint nor one of its
-- own. This replaces the golden slot, which was a room reserved per set that
-- was never leased: it cost a room of map, only loaded when somebody happened
-- to stand near it, and failed nearly every capture it ever attempted. A
-- sibling is strictly better -- it is a real room from the same set, and it
-- exists precisely when we are able to do anything at all.
--
-- Still homogenising, so still a last resort, and callers report when they
-- have had to reach for it.
function Manifest.anySibling(roomSetId)
    local shipped = Core.blueprints[roomSetId]
    if shipped then
        for index in pairs(shipped.slots) do
            local view = Core.shippedBlueprint(roomSetId, index)
            if view then
                return view
            end
        end
    end
    for _, manifest in pairs(slotStore(roomSetId)) do
        return manifest
    end
    return nil
end

--- Capture one slot's own blueprint.
--
-- Called on first lease, while the room is still pristine. Refuses a partial
-- read: an unloaded square would silently become a hole in the blueprint, and
-- unlike the golden slot there is no second chance at this, because the room
-- stops being pristine the moment the tenant touches anything.
function Manifest.captureSlot(roomSetId, index, force)
    local set = Core.roomSets[roomSetId]
    if not set then
        return nil, "unknown room set"
    end

    local slots = slotStore(roomSetId)
    local key = tostring(index)
    if slots[key] and not force then
        return slots[key]
    end

    local captured, present, missing = scan(set, index)
    if missing > 0 then
        return nil, string.format("%d of %d squares not loaded", missing, present + missing)
    end
    if captured.objectCount == 0 then
        return nil, "loaded but nothing to capture"
    end

    slots[key] = captured
    Core.logLn(describe(roomSetId .. "#" .. index, "slot", captured, Manifest.measure(captured)))
    return captured
end

--- The blueprint to rebuild a given slot from, best source first.
--
--   shipped   generated by PhunInteriors.author from the map itself and
--             shipped in the mod. Authoritative: it is what the author built,
--             not whatever state the world left the room in.
--   slot      scanned at runtime on first lease. The fallback for room sets
--             that ship nothing, which is any third party set whose author
--             has not run the tool.
--   sibling   another room from the same set. Homogenising, so genuinely a
--             last resort, but better than refusing to reset the room.
--
-- Which one was used is returned, because a scrub that quietly reaches for
-- a sibling is a scrub that quietly makes every room identical.
function Manifest.forSlot(roomSetId, index)
    local shipped = Core.shippedBlueprint(roomSetId, index)
    if shipped then
        return shipped, "shipped"
    end

    local own = slotStore(roomSetId)[tostring(index)]
    if own then
        return own, "slot"
    end
    local sibling = Manifest.anySibling(roomSetId)
    if sibling then
        return sibling, "sibling"
    end
    return nil, nil
end

function Manifest.forgetSlot(roomSetId, index)
    slotStore(roomSetId)[tostring(index)] = nil
end

--- Every captured blueprint and what it weighs.
function Manifest.report()
    local lines = {}
    local total, untotal, count = 0, 0, 0

    local function add(label, manifest)
        local size = Manifest.measure(manifest)
        total = total + size.withPalette
        untotal = untotal + size.withoutPalette
        count = count + 1
        table.insert(lines, string.format(
            "%s (v%d): %d placements, %d distinct sprites, ~%d bytes",
            label, manifest.version or 1, size.placements, size.distinct, size.withPalette))
    end

    for roomSetId in pairs(Core.blueprints or {}) do
        local shipped = Core.blueprints[roomSetId]
        for index in pairs(shipped.slots) do
            add(roomSetId .. "#" .. index .. " [shipped]", Core.shippedBlueprint(roomSetId, index))
        end
    end

    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    for roomSetId, slots in pairs(Core.data.slotManifests or {}) do
        for index, manifest in pairs(slots) do
            add(roomSetId .. "#" .. index .. " [captured]", manifest)
        end
    end

    if count == 0 then
        return {"no blueprints captured yet"}
    end

    table.sort(lines)
    table.insert(lines, string.format(
        "%d blueprint(s), ~%d bytes total; ~%d without the palette",
        count, total, untotal))
    return lines
end

return Manifest
