require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Holders that are not vehicles.
--
-- A lease key has always been a string, and `admin:<username>` already proved
-- a holder need not be a vehicle. This is the third kind: a world object, of
-- which a tent is the first and the reason the rest exists. The fourth is no
-- holder at all -- `room:<uuid>`, for a room another mod puts people into.
--
-- Four questions separate one holder kind from another -- which rooms it may
-- lease, where its tenant comes back out, what settles the power debt, and
-- what carries the weight. Everything else in the mod -- the leash, the
-- scrub, capture, quarantine, reclaim, the safehouse guard -- keys on room and
-- slot index and never asks what is holding the lease.
-- ---------------------------------------------------------------------------

--- What a lease key is held by. The only thing that reads the prefix.
--
-- Vehicle ids are getRandomUUID strings and contain no colon, so namespacing
-- the other three cannot collide with one.
function Core.holderKind(leaseKey)
    if type(leaseKey) ~= "string" then
        return "vehicle"
    end
    if string.sub(leaseKey, 1, 6) == "admin:" then
        return "admin"
    end
    if string.sub(leaseKey, 1, 7) == "object:" then
        return "object"
    end
    if string.sub(leaseKey, 1, 5) == "room:" then
        return "room"
    end
    return "vehicle"
end

function Core.objectKey(id)
    return "object:" .. tostring(id)
end

--- A lease held by nothing at all: a room another mod put somebody into
--- directly, through Core.enterRoom.
--
-- Minted per LEASE, never per player, and that is the whole reason it is not
-- `admin:<username>`. Several people can stand in one of these at once, and
-- everything that asks "is anybody else in here" -- the hand back on the last
-- exit, the reclaim -- asks it by comparing occupancies against the lease key.
-- A key built from a player would make the room that player's, and the second
-- person in would be holding somebody else's lease.
function Core.roomKey(id)
    return "room:" .. tostring(id)
end

--- What kind of holder this actually is. The companion to holderKind, which
--- answers the same question from a lease key rather than from the thing.
--
-- One test, in one place, because two would drift: Core.roomsForHolder and
-- Core.roomAllows both have to agree about what they are looking at, and they
-- are reached from opposite ends of allocation.
--
-- getScript is the tell rather than instanceof. A BaseVehicle has one and an
-- IsoObject does not, and instanceof is no help here at all -- of a single
-- tent's tiles some load as IsoThumpable and some as plain IsoObject, which
-- is in the API table and cost a spike to find out.
--
-- Admin ports never reach either caller: Slots.acquireIn answers "the room I
-- pointed at" and none of the entitlement machinery applies to it.
function Core.holderKindOf(holder)
    if holder and holder.getScript then
        return "vehicle"
    end
    return "object"
end

-- ---------------------------------------------------------------------------
-- Reading a placed moveable.
--
-- B42 tents are not built objects and `camping.addTent` is a B41 leftover --
-- MOTent.lua is commented out top to bottom. A tent is a placed MOVEABLE, and
-- every sprite of one carries the full type of the kit that put it down as a
-- tile property. That is the binding key: `Base.TentGreen` against thirty-two
-- sprite names per colour.
-- ---------------------------------------------------------------------------

-- Sprite name -> full item type, for moveables whose tile carries no
-- CustomItem. Built once, on first use, because the item scripts are complete
-- long before anybody right clicks anything.
local worldSpriteItems = nil

--- Which item script names this sprite as its WorldObjectSprite, or nil.
--
-- CustomItem is only one of the two ways an item and a tile are tied together,
-- and it is the rarer. Most furniture is the other way round: the generated
-- `Mov_*` items in scripts/generated/items/moveable.txt carry
-- `WorldObjectSprite = fixtures_bathroom_01_0` and the tile says nothing about
-- them at all -- `Mov_FancyToilet` appears in no .tiles file. So an object
-- binding naming one matched nothing, silently, and the menu never offered it.
--
-- `Item.getWorldObjectSprite` has no vanilla lua uses, which by the rule in
-- CLAUDE.md is a reason to guard rather than trust; it is a plain getter over
-- the script field and every failure here falls back to "not a moveable".
-- Where two items share a sprite the lowest full type wins, so the answer does
-- not depend on script load order.
--
-- And WorldObjectSprite names ONE facing. A toilet turned to face another way
-- is another sprite, related to the first only by its tile properties:
-- `Facing` plus `Noffset`/`Woffset`/`Soffset`/`Eoffset`, each an offset in the
-- same sheet to the sprite for that face. That is how vanilla finds them
-- (ISMoveableSpriteProps:getFaces), so every face is indexed too -- below any
-- item that names that face directly.
local FACE_OFFSETS = {"Noffset", "Woffset", "Soffset", "Eoffset"}

local function facesOf(spriteName)
    local out = {}
    local sheet, id = string.match(spriteName, "^(.-)(%d+)$")
    if not sheet or not getSprite then
        return out
    end
    local ok, sprite = pcall(getSprite, spriteName)
    local props = ok and sprite and sprite:getProperties()
    if not props then
        return out
    end
    for _, key in ipairs(FACE_OFFSETS) do
        if props:has(key) then
            local offset = tonumber(props:get(key))
            if offset and offset ~= 0 then
                table.insert(out, sheet .. tostring(tonumber(id) + offset))
            end
        end
    end
    return out
end

local function claim(map, spriteName, fullType)
    local known = map[spriteName]
    if not known or fullType < known then
        map[spriteName] = fullType
    end
end

function Core.worldSpriteItem(spriteName)
    if not spriteName then
        return nil
    end
    if not worldSpriteItems then
        local direct, faces = {}, {}
        local ok, items = pcall(function()
            return getScriptManager():getAllItems()
        end)
        if ok and items then
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local okSprite, sprite = pcall(function()
                    return item:getWorldObjectSprite()
                end)
                if okSprite and type(sprite) == "string" and sprite ~= "" then
                    local fullType = item:getFullName()
                    claim(direct, sprite, fullType)
                    for _, face in ipairs(facesOf(sprite)) do
                        claim(faces, face, fullType)
                    end
                end
            end
        end
        worldSpriteItems = direct
        local count, extra = 0, 0
        for _ in pairs(direct) do
            count = count + 1
        end
        for face, fullType in pairs(faces) do
            if not direct[face] then
                direct[face] = fullType
                extra = extra + 1
            end
        end
        print(string.format("[PhunInteriors] indexed %d world object sprites, %d more by facing (%s)",
            count, extra, ok and "ok" or tostring(items)))
    end
    return worldSpriteItems[spriteName]
end

--- Forget the sprite index. For the specs, which swap the item scripts.
function Core.resetWorldSpriteItems()
    worldSpriteItems = nil
end

--- The moveable item type this object was placed from, or nil.
function Core.moveableItemOf(object)
    if not object or not object.getSprite then
        return nil
    end
    local sprite = object:getSprite()
    if not sprite then
        return nil
    end
    local props = sprite:getProperties()
    if props and props:has("CustomItem") then
        local item = props:get("CustomItem")
        if type(item) == "string" and item ~= "" then
            return item
        end
    end
    return Core.worldSpriteItem(sprite.getName and sprite:getName())
end

--- The anchor sprite's name of a multi-tile object, or nil for a single tile.
--
-- getAnchorSprite():getName() is exactly how vanilla compares two grids
-- (ISMoveableSpriteProps.lua:960), so every tile of one bed answers the same.
local function anchorNameOf(sprite)
    local ok, name = pcall(function()
        local grid = sprite:getSpriteGrid()
        local anchor = grid and grid:getAnchorSprite()
        return anchor and anchor:getName()
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

--- Every sprite name a binding could name this object by.
--
-- Its own sprite, its other facings, and for a multi-tile object the anchor
-- of its grid and the anchor's facings. So a binding naming
-- `fixtures_bathroom_01_0` still reaches the toilet after somebody rotates it,
-- and a binding naming a bed's anchor reaches whichever tile was clicked. The
-- same two relations the item fallback above follows, from the other end.
function Core.spriteNamesOf(object)
    local out, seen = {}, {}
    local function add(name)
        if name and not seen[name] then
            seen[name] = true
            table.insert(out, name)
        end
    end
    local sprite = object and object.getSprite and object:getSprite()
    local name = sprite and sprite.getName and sprite:getName()
    if not name then
        return out
    end
    add(name)
    for _, face in ipairs(facesOf(name)) do
        add(face)
    end
    local anchor = anchorNameOf(sprite)
    if anchor then
        add(anchor)
        for _, face in ipairs(facesOf(anchor)) do
            add(face)
        end
    end
    return out
end

--- What makes two tiles parts of the same placed thing.
--
-- The moveable item when there is one, which is what a tent has always used.
-- A sprite binding reaches objects with no item at all -- a fixture a map
-- author placed -- and for those the grid's anchor names the design, or the
-- sprite itself for a single tile. Without this a bed bound by sprite would
-- have been one tile wide as far as the lease id is concerned, and a second
-- tile clicked would mint a second id and take a second room.
function Core.holderIdentity(object)
    local item = Core.moveableItemOf(object)
    if item then
        return item
    end
    local sprite = object and object.getSprite and object:getSprite()
    if not sprite then
        return nil
    end
    return anchorNameOf(sprite) or (sprite.getName and sprite:getName()) or nil
end

--- Where a multi-tile moveable's north-west corner is, and every object in it.
--
-- A tent spans several squares -- a green one is at least 2x4 -- and any of
-- them can be right clicked. Rather than inventing a rule for which tile is
-- the holder, the sprite grid already answers it: getAnchorSprite names the
-- design and getSpriteGridPosX/Y give this tile's offset within it, so the
-- origin is the clicked square minus that offset. It is what vanilla's own
-- pickup path computes, at ISMoveableSpriteProps.lua:1003.
--
-- Returns nil for a single-tile object, which is not a failure: the caller
-- treats the object's own square as the anchor.
function Core.moveableGrid(object)
    if not object or not object.getSprite then
        return nil
    end
    local sprite = object:getSprite()
    local square = object.getSquare and object:getSquare()
    if not sprite or not square then
        return nil
    end

    local ok, grid = pcall(function()
        return sprite:getSpriteGrid()
    end)
    if not ok or not grid then
        return nil
    end

    local originX = square:getX() - grid:getSpriteGridPosX(sprite)
    local originY = square:getY() - grid:getSpriteGridPosY(sprite)
    local originZ = square:getZ() - grid:getSpriteGridPosZ(sprite)

    return {
        x = originX,
        y = originY,
        z = originZ,
        width = grid:getWidth(),
        height = grid:getHeight(),
        levels = grid:getLevels(),
        grid = grid
    }
end

--- Every object making up this placed moveable, the clicked one included.
--
-- Matched by identity rather than by walking the grid's sprite list, because a
-- tile may hold several objects and only one of them is the tent. Single-tile
-- objects come back as a list of one.
function Core.moveableTiles(object)
    local out = {}
    local item = Core.holderIdentity(object)
    if not item then
        return out
    end

    local extent = Core.moveableGrid(object)
    if not extent then
        table.insert(out, object)
        return out
    end

    local cell = getCell()
    for dz = 0, math.max(1, extent.levels or 1) - 1 do
        for dx = 0, extent.width - 1 do
            for dy = 0, extent.height - 1 do
                local square = cell and cell:getGridSquare(extent.x + dx, extent.y + dy, extent.z + dz)
                local objects = square and square:getObjects()
                for i = 0, (objects and objects:size() or 0) - 1 do
                    local candidate = objects:get(i)
                    if candidate and Core.holderIdentity(candidate) == item then
                        table.insert(out, candidate)
                    end
                end
            end
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- The lease id, and why it lives where it does.
-- ---------------------------------------------------------------------------

--- Put a key on every tile of a placed moveable, or take it off with nil.
--
-- Every tile rather than the anchor, because any of them can be right clicked
-- and a reader is handed whichever one the player touched.
--
-- Writes only when the value actually changes, so a caller that re-asserts the
-- same state on every entry -- which both of ours do -- costs one comparison
-- per tile rather than a network message.
local function writeTiles(tiles, key, value)
    for _, tile in ipairs(tiles) do
        local md = tile:getModData()
        if type(md.movableData) ~= "table" then
            md.movableData = {}
        end
        if md.movableData[key] ~= value then
            md.movableData[key] = value
            -- Unlike a vehicle, an object really does have a transmit path:
            -- IsoObject.transmitModData addresses a plain object by its index
            -- in square:getObjects(), and AddSpecialObject puts a placed
            -- moveable in that list. In single player both network flags are
            -- false and it falls through to flagForHotSave, which is what
            -- makes the write persist.
            if tile.transmitModData then
                tile:transmitModData()
            end
        end
    end
end

--- The first movableData value for this key on any tile of a moveable.
local function readTiles(tiles, key)
    for _, tile in ipairs(tiles) do
        if tile.hasModData and tile:hasModData() then
            local bag = tile:getModData().movableData
            if type(bag) == "table" and bag[key] ~= nil then
                return bag[key]
            end
        end
    end
    return nil
end

--- Read or create the durable id of an object holding a lease.
--
-- STORED INSIDE modData.movableData, NOT at the top level, and that is the
-- whole reason this is not two lines.
--
-- Vanilla carries an object's modData through a pickup in two different ways
-- depending on the object's CLASS. ISMoveableSpriteProps:pickUpMoveableInternal
-- copies the ENTIRE table for an IsoThumpable, through
-- saveThumpableParameters, and for anything else copies only `movableData`,
-- container custom names and `itemCondition`. Placement mirrors it:
-- restoreThumpableParameters puts every key back, and placeMoveableInternal
-- copies `movableData` across on its own.
--
-- A tent is BOTH classes at once. Of one TentGreen's tiles, camping_04_100
-- loads as a plain IsoObject and camping_04_103 as an IsoThumpable -- probed
-- in game, see the API table. So a top level key survives being picked up by
-- one tile of a tent and is silently dropped by another. `movableData` is the
-- one channel both branches of pickUpMoveableInternal carry, both ways, so it
-- is the right place for anything that has a chance of surviving.
--
-- IT DOES NOT MAKE THE ID SURVIVE A PICKUP, and nothing can. A tent carries
-- ForceSingleItem, and that branch of pickUpMoveable never reaches
-- pickUpMoveableInternal's item at all: it builds a fresh one from the anchor
-- sprite and copies modData onto it only when the object on the CLICKED square
-- is an IsoThumpable. Click the other corner and the item carries nothing.
--
-- So the lease must never depend on the id surviving a pickup, and the tent
-- must refuse to be picked up while its room is anybody's -- see "Known gaps"
-- in CLAUDE.md. What movableData and the write-to-every-tile below buy is the
-- case that does work: the id surviving a save, a reload and a chunk unload,
-- which is all the lease itself needs.
function Core.objectId(object, create)
    if not object or not object.getModData then
        return nil
    end

    local tiles = Core.moveableTiles(object)
    if #tiles == 0 then
        tiles = {object}
    end

    -- Any tile that already carries one wins, so a second call never mints a
    -- second id for the same tent.
    local existing = readTiles(tiles, Core.consts.objectIdKey)

    if not existing then
        if not create then
            return nil
        end
        existing = tostring(getRandomUUID())
    end

    writeTiles(tiles, Core.consts.objectIdKey, existing)
    return existing
end

-- ---------------------------------------------------------------------------
-- The pickup lock.
--
-- A tent's lease cannot survive the tent being picked up -- see the API table,
-- and the reason is that ForceSingleItem rebuilds the item from the anchor
-- sprite and copies modData onto it only when the CLICKED tile happens to be
-- an IsoThumpable, which of one tent's tiles some are and some are not. So a
-- tent picked up by one corner carries its id and by another carries nothing,
-- and putting it back down would mint a fresh id, take a fresh room, and leave
-- the old one leased to an id nothing holds until reclaim eventually took it.
-- That is a tenant's belongings disappearing quietly, which is the one failure
-- this whole design is built to avoid.
--
-- Rather than make the lease survive something it cannot survive, the tent
-- refuses to be picked up while its room is anybody's. Two separate tests, and
-- they are separate because they are true at different times and answered from
-- different places -- see Slots.lockReason.
--
-- THIS FLAG IS NOT THE TEST. It is a copy of the server's answer, put where a
-- client can read it synchronously, because canPickUpMoveable is asked and
-- answered in one frame and the client does not know whose lease is whose. A
-- client could forge it; a client could equally just not run the guard, which
-- is true of the destroy guards as well and is the reason neither of them is
-- what contains anybody. The server re-asserts it on every entry and on every
-- arrival back, so a stale one cannot outlive the next visit.
-- ---------------------------------------------------------------------------

--- Why this object may not be packed away, or nil when it may be.
function Core.objectLock(object)
    if not object or not object.getModData then
        return nil
    end
    local tiles = Core.moveableTiles(object)
    if #tiles == 0 then
        tiles = {object}
    end
    return readTiles(tiles, Core.consts.objectLockKey)
end

--- Record why it may not be, or clear it with nil.
function Core.setObjectLock(object, reason)
    if not object or not object.getModData then
        return
    end
    local tiles = Core.moveableTiles(object)
    if #tiles == 0 then
        tiles = {object}
    end
    writeTiles(tiles, Core.consts.objectLockKey, reason)
end

--- The locked object on this square, and why, or nil.
--
-- Reads the square rather than an object because the guard is handed one and
-- not the other: canPickUpMoveable's multi-sprite path passes nil for a tile
-- whose entry is a sprite instance rather than an object, so the square is the
-- only argument that is always there.
function Core.lockedObjectOn(square)
    if not square then
        return nil
    end
    local objects = square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local object = objects:get(i)
        -- Deliberately reads this tile only. Walking the whole grid would mean
        -- a sprite grid lookup per object per frame of hovering, and every
        -- tile carries the flag precisely so that it does not have to.
        if object and object.hasModData and object:hasModData() then
            local bag = object:getModData().movableData
            local reason = type(bag) == "table" and bag[Core.consts.objectLockKey] or nil
            if reason then
                return object, reason
            end
        end
    end
    return nil
end

--- The bound object on a square, if there is one, with its anchor position.
--
-- Returns the object, its lease id, and the square its grid starts at. The
-- server calls this with coordinates a client sent, so nothing about the
-- object's identity has to be taken on trust -- the same shape as resolving a
-- vehicle from a position rather than from an id.
function Core.boundObjectAt(x, y, z)
    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z or 0)
    if not square then
        return nil
    end

    local objects = square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local object = objects:get(i)
        if object and Core.objectHasRooms(object) then
            local extent = Core.moveableGrid(object)
            return object, (extent or {
                x = square:getX(),
                y = square:getY(),
                z = square:getZ()
            })
        end
    end

    return nil
end

return true
