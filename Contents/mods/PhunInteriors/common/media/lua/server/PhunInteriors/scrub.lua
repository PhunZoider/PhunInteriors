if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = require "PhunInteriors/manifest"
local Slots = require "PhunInteriors/slots"
local Scrub = {}
Core.modules.scrub = Scrub

-- ---------------------------------------------------------------------------
-- Restore a quarantined slot to its manifest.
--
-- This is an idempotent rebuild, not a diff. Clear every non structural object
-- in the bounds, then re-place the manifest fresh. Added furniture, smashed
-- walls, damaged walls and dragged furniture are then all the same operation,
-- and it does not matter how the room got into its current state.
--
-- Note this is a scrub, not a chunk revert. No Lua call reloads a chunk from
-- its lotpack; PZ persists modified chunks into the save. Because we author
-- every room, rebuilding from a manifest is equivalent in practice.
-- ---------------------------------------------------------------------------

local function clearSquare(square, keepLoot, salvage)
    local objects = square:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        if object and not instanceof(object, "IsoFloor") then
            if keepLoot and salvage and instanceof(object, "IsoWorldInventoryObject") then
                local item = object:getItem()
                if item then
                    table.insert(salvage, item)
                end
            end
            square:transmitRemoveItemFromSquare(object)
            square:RemoveTileObject(object)
        end
    end

    -- Things a sprite scan cannot capture, handled explicitly
    local container = square:getContainer()
    if container then
        if keepLoot and salvage then
            local items = container:getItems()
            for i = 0, items:size() - 1 do
                table.insert(salvage, items:get(i))
            end
        end
        container:removeAllItems()
    end

    -- corpses and blood do not belong to the next tenant
    local body = square:getDeadBody()
    if body then
        body:removeFromSquare()
        body:removeFromWorld()
    end
    -- IsoGridSquare has no setBloodSplatLifetime. This pair is what vanilla
    -- ISCleanBlood:complete() uses.
    square:removeBlood(false, false)
    square:removeGrime()
end

local function restoreSquare(square, sprites)
    for _, name in ipairs(sprites) do
        local object = IsoObject.new(getCell(), square, name)
        square:AddTileObject(object)
        object:transmitCompleteItemToClients()
    end
end

--- Rebuild one slot from the manifest of its room set.
-- Returns true plus any salvaged loot, or false plus a reason.
function Scrub.slot(roomSetId, index)
    local set = Core.roomSets[roomSetId]
    if not set then
        return false, "unknown room set"
    end

    local manifest = Manifest.get(roomSetId) or Manifest.capture(roomSetId)
    if not manifest then
        return false, "no manifest yet"
    end

    local bounds = Core.slotBounds(set, index)
    local origin = Core.slotOrigin(set, index)
    local keepLoot = Core.settings.ScrubKeepsLoot
    local salvage = keepLoot and {} or nil
    local touched = 0

    -- Verify the whole slot is loaded before mutating any of it, so a scrub is
    -- never left half applied.
    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                if not getCell():getGridSquare(x, y, z) then
                    return false, "chunk not loaded"
                end
            end
        end
    end

    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                clearSquare(square, keepLoot, salvage)
                local key = (x - origin.x) .. "," .. (y - origin.y) .. "," .. (z - origin.z)
                local sprites = manifest.squares[key]
                if sprites then
                    restoreSquare(square, sprites)
                end
                touched = touched + 1
            end
        end
    end

    Core.logLn("scrubbed " .. roomSetId .. "#" .. index .. " (" .. touched .. " squares)")
    return true, salvage
end

--- Work the quarantine queue. Slots whose chunk is not loaded go back on the
--- queue and are retried on the next pass.
function Scrub.processQueue(limit)
    limit = limit or 1
    local done = 0
    local deferred = {}

    while done < limit do
        local entry = Slots.nextQuarantined()
        if not entry then
            break
        end
        local ok, reason = Scrub.slot(entry.roomSet, entry.index)
        if ok then
            done = done + 1
        else
            Core.debugLn("deferring scrub of " .. entry.roomSet .. "#" .. entry.index ..
                ": " .. tostring(reason))
            table.insert(deferred, entry)
            break
        end
    end

    local store = Slots.store()
    for _, entry in ipairs(deferred) do
        table.insert(store.quarantine, entry)
    end

    return done
end

return Scrub
