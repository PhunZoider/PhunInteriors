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
-- Blueprints are **scanned, never hand authored**. A blueprint is a photograph
-- of what the map author built, taken while the room is still pristine, and
-- used to put the room back after a tenant. The map is the source of truth;
-- this is only how a scrub knows what "back" means.
--
-- Three sources, best first, resolved by Manifest.forSlot:
--
--   captured  scanned at runtime the first time THAT SLOT is leased, and kept
--             in global ModData under data.roomManifests[roomId].slots[index].
--             A slot that has never been leased has never been modified, so it
--             is pristine by definition -- which is the whole reason
--             Slots.markUsed only ever allows one capture window per slot.
--   shipped   a room-level blueprint registered by a generated file, if the
--             author shipped one. Optional: the emitter no longer writes them.
--   sibling   another slot of the same room. Homogenising, so a last resort,
--             and it only fires for a slot that missed its one window.
--
-- Per SLOT, and that is a deliberate reversal. It was per room for a while, on
-- the reasoning that a room is one design so a stamp that came out wrong
-- should be repaired rather than preserved. True, but worth very little here:
-- containment is the leash and not the walls, so a mis-stamped room is
-- cosmetic, and the price was that every stamp had to look identical. Per slot
-- buys varied decor -- wallpaper, carpet, overlays -- while the ROOM stays
-- opinionated about shape, exits, generator and what vehicle fits. The room is
-- the contract; the blueprint is what is actually on the squares.
--
-- It also stops the shipped blueprint being load bearing, which removes a
-- silent trap: repaint a room in the editor, forget to re-export, and the
-- first scrub used to quietly undo the repaint.
--
-- Stored shape, with the palette pooled across the room's slots:
--
--   data.roomManifests[roomId] = {
--     version = 2,
--     palette = {"sprite_a", "sprite_b", ...},   -- distinct names, 1 based
--     slots   = {[7] = {["dx,dy,dz"] = {1, 2, 2}}}
--   }
--
-- Measured on the borrowed van room: 29 objects from 11 distinct sprites, 379
-- bytes against 699 without the palette. So a few hundred blueprints is on the
-- order of 100KB. The palette halves that and costs nothing to keep, but size
-- was never the constraint it was assumed to be.
-- ---------------------------------------------------------------------------

local MANIFEST_VERSION = 2

-- How many leash ticks we keep trying a first lease capture before giving up.
-- Four a second, so this is ten seconds.
--
-- There is no longer anywhere to fall back TO, and that is the point. A room
-- is one design, so a capture taken from any of its slots is the blueprint for
-- all of them -- which is what the old sibling branch was reaching for by
-- hand. Giving up now just means this room still has no blueprint and the next
-- tenant of any slot gets another go.
Manifest.CAPTURE_ATTEMPTS = 40

--- Everything captured for one room: a pooled palette and a table of slots.
--
-- Per SLOT, under a palette shared by the whole room:
--
--   data.roomManifests[roomId] = {
--     version = 2,
--     palette = {"sprite_a", "sprite_b", ...},   -- distinct names, 1 based
--     slots   = {[7] = {["dx,dy,dz"] = {1, 2, 2}}}
--   }
--
-- Per slot, because that is what lets a map author decorate the stamps
-- differently -- different wallpaper, carpet, overlays -- while the room stays
-- opinionated about the shape, the exits and where the generator goes. The
-- room is the contract; the blueprint is what is actually on the squares, and
-- only the slot itself knows that.
--
-- The palette is pooled because it is the part that would otherwise be
-- duplicated. Sprite names are long -- `overlay_grime_wall_01_16` is 24
-- characters -- and a room's fourteen or so of them are over half of each
-- manifest. Stored per slot that is the same list 120 times, tens of KB of
-- pure repetition, and repetition precisely because the stamps are near
-- identical. Pooled, a slot with different wallpaper adds an entry or two
-- rather than a whole second copy. It is the same trick the emitter used at
-- export time, moved to capture time.
local function roomStore(roomId)
    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    Core.data.roomManifests = Core.data.roomManifests or {}
    local store = Core.data.roomManifests
    store[roomId] = store[roomId] or {
        version = MANIFEST_VERSION,
        palette = {},
        slots = {}
    }
    return store[roomId]
end

--- Fold a freshly scanned slot into the room's pooled palette.
--
-- The scan built its own palette, 1 based and local to itself, so every index
-- in its squares has to be remapped onto the room's. Names already in the
-- pooled palette are reused; new ones are appended.
local function pool(room, captured)
    local remap = {}
    local seen = {}
    for i, name in ipairs(room.palette) do
        seen[name] = i
    end
    for localIndex, name in ipairs(captured.palette) do
        local shared = seen[name]
        if not shared then
            table.insert(room.palette, name)
            shared = #room.palette
            seen[name] = shared
        end
        remap[localIndex] = shared
    end

    local squares = {}
    for key, indices in pairs(captured.squares) do
        local mapped = {}
        for _, localIndex in ipairs(indices) do
            table.insert(mapped, remap[localIndex])
        end
        squares[key] = mapped
    end
    return squares
end

--- One slot's blueprint, in the shape spritesAt and the scrub expect.
--
-- A view borrowing the room's palette rather than a copy, because every reader
-- only ever reads. Nil when this slot has never captured.
local function viewOf(roomId, index)
    local room = Core.data and Core.data.roomManifests and Core.data.roomManifests[roomId]
    local squares = room and room.slots and room.slots[index]
    if not squares then
        return nil
    end
    return {
        version = room.version or MANIFEST_VERSION,
        palette = room.palette,
        squares = squares
    }
end

--- Has this particular slot ever captured?
--
-- Distinct from "can this slot be resolved", which the fallbacks below also
-- answer. The leash needs this one: resolution succeeding through a sibling
-- must not stop a slot capturing its own, or the first slot to capture would
-- freeze the whole room at its decor.
function Manifest.hasCapture(roomId, index)
    return viewOf(roomId, index) ~= nil
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
    -- A reservoir a tenant installed belongs to the tenant, not the room.
    -- Captured, every scrub would restore it -- free, forever, and through
    -- createFromSprite as a picture of a barrel. Left out, a scrub removes it
    -- like anything else brought in. The map's own barrels carry no tag and
    -- are captured like any other fixture.
    if object:hasModData() and object:getModData()[Core.consts.reservoirKey] then
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
local function scan(room, index)
    local bounds = Core.slotBounds(room, index)
    local origin = Core.slotOrigin(room, index)
    if not bounds then
        return nil, 0, 0
    end
    local squares = {}
    local palette = {}
    local seen = {}
    local total = 0
    local present = 0
    local missing = 0

    -- +1 on z so a roof, or anything else built over the room, is captured too.
    --
    -- Only the room's OWN level has to read completely. A nil square above it
    -- is empty air, not a chunk that failed to load, and counting it as missing
    -- made capture impossible on this map: an unroofed room has no z=1 squares
    -- at all, and a roofed one has six -- its 2x3 floor -- against a 3x4
    -- footprint, so the wall column and row come back nil either way. Every
    -- capture refused, on every attempt, silently, and the slot's one window
    -- closed with nothing in it.
    --
    -- The strictness is still right for the room's own level, where a nil
    -- square really does mean the chunk is not there: a hole in a blueprint is
    -- a square every future scrub clears and never refills.
    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                if not square then
                    if z == bounds.z then
                        missing = missing + 1
                    end
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
-- Public so the authoring tool can scan a room that is not registered
-- yet: it takes the set definition rather than an id, and Core.slotBounds
-- only needs the slot map and the size, so a half built definition works. The
-- reason for the failure comes back with it, because the author sweeping a
-- strip needs to know which slots they still have to walk to.
function Manifest.scanSlot(room, index)
    local captured, present, missing = scan(room, index)
    if not captured then
        return nil, "no such slot in this room"
    end
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

local function describe(roomId, label, captured, size)
    return string.format(
        "captured %s for %s: %d objects, %d distinct sprites, ~%d bytes (~%d without the palette)",
        label, roomId, captured.objectCount, size.distinct, size.withPalette, size.withoutPalette)
end

--- Capture one slot's blueprint.
--
-- Called on first lease, while that slot is still pristine. Refuses a partial
-- read of the room's own level: a hole in a blueprint is a square every future
-- scrub clears and never refills.
--
-- Per slot rather than per room, so a map author can decorate the stamps
-- differently and each one is restored to what it actually was. Slots.markUsed
-- is what makes it trustworthy -- a slot only ever gets one capture window,
-- because after a tenant it is no longer evidence of anything.
function Manifest.captureSlot(roomId, index, force)
    local room = Core.rooms[roomId]
    if not room then
        return nil, "unknown room"
    end

    local store = roomStore(roomId)
    if store.slots[index] and not force then
        return viewOf(roomId, index)
    end

    local captured, present, missing = scan(room, index)
    if missing > 0 then
        -- The chunk is not loaded. Not a failure, just not now -- and caching
        -- an empty scan would poison every future scrub of this slot.
        return nil, string.format("%d of %d squares not loaded", missing, present + missing)
    end
    if captured.objectCount == 0 then
        return nil, "loaded but nothing to capture"
    end

    store.slots[index] = pool(store, captured)
    Core.logLn(describe(roomId .. "#" .. index, "slot", captured, Manifest.measure(captured)))
    return viewOf(roomId, index)
end

--- Any other slot of this room that has captured. Last resort only.
--
-- Homogenising, so it is deliberately the bottom of the resolution order: it
-- restores this slot to look like a different one, losing whatever the map
-- author actually painted here. It exists because the alternative is worse --
-- a slot with no blueprint can never be scrubbed at all, so it accumulates
-- every tenant's leavings forever.
--
-- It only ever fires for a slot that missed its one capture window, which
-- should be rare: capture rides the leash, so it runs at the moment a player
-- is provably standing in the room with the chunk loaded.
function Manifest.anySibling(roomId)
    local room = Core.data and Core.data.roomManifests and Core.data.roomManifests[roomId]
    if not room or not room.slots then
        return nil
    end
    for index in pairs(room.slots) do
        return viewOf(roomId, index)
    end
    return nil
end

--- The blueprint to rebuild a given slot from, best source first.
--
--   captured  this slot's own, scanned at runtime on its first lease. What
--             the map author actually built HERE, so it is what a scrub
--             should restore, and it is why the stamps may differ.
--   shipped   a room-level blueprint from a generated file, if the author
--             shipped one. Optional now -- the emitter no longer writes them
--             -- but still honoured, because a third party may want every
--             server to restore its rooms identically.
--   sibling   another slot of the same room. Homogenises, so genuinely last.
--
-- The order is the whole point of this shape, and it is the reverse of what it
-- used to be. Shipped used to beat the slot's own capture, which meant a
-- per-slot capture could never mean anything and every room in a set was
-- flattened to one decor. The slot's own observation is the most specific
-- truth available, so it wins.
--
-- Which source was used is returned, because a scrub reaching for a sibling is
-- one that is about to overwrite what somebody painted, and that should be
-- visible in a log rather than silent.
function Manifest.forSlot(roomId, index)
    local own = viewOf(roomId, index)
    if own then
        return own, "captured"
    end
    local shipped = Core.roomBlueprint(roomId)
    if shipped then
        return shipped, "shipped"
    end
    local sibling = Manifest.anySibling(roomId)
    if sibling then
        return sibling, "sibling"
    end
    return nil, nil
end

function Manifest.forgetSlot(roomId, index)
    local room = Core.data and Core.data.roomManifests and Core.data.roomManifests[roomId]
    if room and room.slots then
        room.slots[index] = nil
    end
end


--- Every blueprint and what it weighs.
--
-- Reports the pooled palette once per room and each slot's squares separately,
-- because that is how it is actually stored and the whole point of pooling is
-- that the palette is NOT paid for per slot. Adding the palette into every
-- slot's figure would report the duplication the pooling exists to avoid.
function Manifest.report()
    local lines = {}
    local total, count, rooms = 0, 0, 0

    local function measureSquares(palette, squares)
        return Manifest.measure({
            palette = palette,
            squares = squares
        })
    end

    for roomId, shipped in pairs(Core.blueprints or {}) do
        local size = Manifest.measure(shipped)
        total = total + size.withPalette
        count = count + 1
        table.insert(lines, string.format(
            "%s [shipped] (v%d): %d placements, %d distinct sprites, ~%d bytes",
            roomId, shipped.version or 1, size.placements, size.distinct, size.withPalette))
    end

    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    for roomId, room in pairs(Core.data.roomManifests or {}) do
        local paletteBytes = 0
        for _, name in ipairs(room.palette or {}) do
            paletteBytes = paletteBytes + #name
        end
        rooms = rooms + 1
        total = total + paletteBytes

        local slots, squareBytes, placements = 0, 0, 0
        for index, squares in pairs(room.slots or {}) do
            local size = measureSquares(room.palette, squares)
            slots = slots + 1
            squareBytes = squareBytes + size.withPalette - paletteBytes
            placements = placements + size.placements
            total = total + (size.withPalette - paletteBytes)
            count = count + 1
        end

        table.insert(lines, string.format(
            "%s [captured] (v%d): %d slot(s), %d placements, %d shared sprites, " ..
                "~%d bytes of palette + ~%d of squares",
            roomId, room.version or MANIFEST_VERSION, slots, placements,
            #(room.palette or {}), paletteBytes, squareBytes))
    end

    if count == 0 then
        return {"no blueprints captured yet"}
    end

    table.sort(lines)
    table.insert(lines, string.format(
        "%d blueprint(s) across %d room(s), ~%d bytes total", count, rooms, total))
    return lines
end

return Manifest
