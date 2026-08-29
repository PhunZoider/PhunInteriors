if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = {}
Core.modules.manifest = Manifest

-- ---------------------------------------------------------------------------
-- What a fresh room of a given type looks like.
--
-- We do not hand author this. Slot 0 of every room set is a golden slot that
-- is never leased; we scan it once and cache the result. Nothing to maintain,
-- nothing to drift, and it regenerates itself when the borrowed map is
-- replaced with our own.
-- ---------------------------------------------------------------------------

local function store()
    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    Core.data.manifests = Core.data.manifests or {}
    return Core.data.manifests
end

--- Objects that describe the room itself, as opposed to its contents.
local function isStructural(object)
    if not object then
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

--- Read one slot into a per square list of sprite names.
local function scan(set, index)
    local bounds = Core.slotBounds(set, index)
    local origin = Core.slotOrigin(set, index)
    local squares = {}
    local total = 0

    -- +1 on z so the power square on the roof is captured too
    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                if square then
                    local sprites = {}
                    local objects = square:getObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if isStructural(object) then
                            local sprite = object:getSprite()
                            local name = sprite and sprite:getName()
                            if name then
                                table.insert(sprites, name)
                                total = total + 1
                            end
                        end
                    end
                    if #sprites > 0 then
                        -- relative, so the manifest applies to every slot
                        local key = (x - origin.x) .. "," .. (y - origin.y) .. "," .. (z - origin.z)
                        squares[key] = sprites
                    end
                end
            end
        end
    end

    return {
        squares = squares,
        objectCount = total,
        capturedAt = Core.now()
    }
end

--- Capture the golden slot for a room set. Chunks must be loaded, so this is
--- driven from the scrub scheduler rather than called at start up.
function Manifest.capture(roomSetId, force)
    local set = Core.roomSets[roomSetId]
    if not set then
        return nil
    end

    local cache = store()
    if cache[roomSetId] and not force then
        return cache[roomSetId]
    end

    local captured = scan(set, Core.consts.goldenSlot)
    if captured.objectCount == 0 then
        -- an empty scan means the chunk was not loaded, not that the room is
        -- empty. caching that would poison every future scrub.
        Core.debugLn("golden slot for " .. roomSetId .. " scanned empty, not caching")
        return nil
    end

    cache[roomSetId] = captured
    Core.logLn("captured manifest for " .. roomSetId .. ": " .. captured.objectCount .. " objects")
    return captured
end

function Manifest.get(roomSetId)
    return store()[roomSetId]
end

function Manifest.forget(roomSetId)
    store()[roomSetId] = nil
end

return Manifest
