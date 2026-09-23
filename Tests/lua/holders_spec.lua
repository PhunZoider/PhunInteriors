-- Holders that are not vehicles: the object binding, the specificity it
-- contributes, and the lease id's storage.
--
-- What this CANNOT see is anything needing a real IsoGridSquare, which here is
-- the sprite grid walk in Core.moveableTiles -- the stubs' world is empty, so
-- a multi-tile object falls back to the single object it was handed. The grid
-- arithmetic itself is testable and is; enumerating the tiles is not, and
-- belongs in game.

local root = os.getenv("PI_ROOT") or "."
local stubs = dofile(root .. "/Tests/lua/stubs.lua")
stubs.install(root)

require "PhunInteriors/registry"
local Core = PhunInteriors
local r = stubs.reporter()

-- ---------------------------------------------------------------------------
-- Fakes. A placed moveable is a sprite with a CustomItem property; that is the
-- whole of what the binding reads.
-- ---------------------------------------------------------------------------

local function fakeSprite(name, customItem, grid)
    return {
        getName = function() return name end,
        getProperties = function()
            return {
                has = function(_, key) return key == "CustomItem" and customItem ~= nil end,
                get = function(_, key) return key == "CustomItem" and customItem or nil end
            }
        end,
        getSpriteGrid = function() return grid end
    }
end

local function fakeObject(spriteName, customItem, grid, square)
    local md = {}
    local object
    object = {
        getSprite = function() return object.sprite end,
        getSquare = function() return square end,
        getModData = function() return md end,
        hasModData = function() return next(md) ~= nil end,
        transmitModData = function() object.transmitted = (object.transmitted or 0) + 1 end
    }
    object.sprite = fakeSprite(spriteName, customItem, grid)
    return object
end

local function room(id)
    Core.registerRoom(id, {
        size = {w = 3, h = 4},
        locations = {[0] = {1000, 1000, 0}, [1] = {1100, 1000, 0}}
    })
end

-- ---------------------------------------------------------------------------
-- The binding.
-- ---------------------------------------------------------------------------

room("t.tent")
room("t.van")

Core.registerObjects({
    id = "t.tents",
    items = {"Base.TentGreen", "Base.TentBlue"},
    rooms = {"t.tent"}
})

local green = fakeObject("camping_04_100", "Base.TentGreen")
local blue = fakeObject("camping_04_36", "Base.TentBlue")
local crate = fakeObject("crate_01_0", "Base.WoodenCrate")
local plain = fakeObject("blends_street_01_48", nil)

r.check("a bound item resolves its room", Core.roomsForObject(green)[1], "t.tent")
r.check("a second bound item resolves the same room", Core.roomsForObject(blue)[1], "t.tent")
r.check("an unbound moveable gets nothing", #Core.roomsForObject(crate), 0)
r.check("an object with no CustomItem gets nothing", #Core.roomsForObject(plain), 0)
r.check("objectHasRooms agrees", Core.objectHasRooms(green), true)
r.check("objectHasRooms agrees for a crate", Core.objectHasRooms(crate), false)

-- Most furniture is tied to its item from the ITEM end: a generated Mov_*
-- script names the sprite, and the tile carries no CustomItem at all. A
-- binding naming Base.Mov_FancyToilet matched nothing until this fallback.
do
    local function fakeItem(fullName, sprite)
        return {
            getFullName = function() return fullName end,
            getWorldObjectSprite = function() return sprite end
        }
    end
    local list = {
        fakeItem("Base.Mov_FancyToilet", "fixtures_bathroom_01_0"),
        fakeItem("Base.Zz_SameSprite", "fixtures_bathroom_01_0"),
        fakeItem("Base.Hammer", nil)
    }
    -- _0 names its south face as _1, the way vanilla's facing offsets do.
    local savedSprite = getSprite
    getSprite = function(name)
        if name ~= "fixtures_bathroom_01_0" then
            return nil
        end
        return {
            getProperties = function()
                return {
                    has = function(_, key) return key == "Soffset" end,
                    get = function(_, key) return key == "Soffset" and "1" or nil end
                }
            end
        }
    end
    local saved = getScriptManager
    getScriptManager = function()
        return {
            getAllItems = function()
                return {
                    size = function() return #list end,
                    get = function(_, i) return list[i + 1] end
                }
            end
        }
    end
    Core.resetWorldSpriteItems()

    room("t.warehouse")
    Core.registerObjects({
        id = "t.toilets",
        items = {"Base.Mov_FancyToilet"},
        rooms = {"t.warehouse"}
    })

    local toilet = fakeObject("fixtures_bathroom_01_0", nil)
    r.check("a sprite named by an item's WorldObjectSprite resolves to it",
        Core.moveableItemOf(toilet), "Base.Mov_FancyToilet")
    r.check("two items on one sprite resolve to the lowest full type",
        Core.worldSpriteItem("fixtures_bathroom_01_0"), "Base.Mov_FancyToilet")
    r.check("the toilet reaches its room", Core.roomsForObject(toilet)[1], "t.warehouse")
    r.check("CustomItem still wins over the sprite index",
        Core.moveableItemOf(fakeObject("fixtures_bathroom_01_0", "Base.TentGreen")), "Base.TentGreen")
    r.check("another facing of the same item resolves to it",
        Core.moveableItemOf(fakeObject("fixtures_bathroom_01_1", nil)), "Base.Mov_FancyToilet")
    r.check("a sprite no item names is still nothing", Core.moveableItemOf(plain), nil)

    getScriptManager = saved
    getSprite = savedSprite
    Core.resetWorldSpriteItems()
end

-- Bound by SPRITE, for things no item stands behind or when the sprite is what
-- the admin could read off the object. Any facing reaches, and so does any tile
-- of a multi-tile object whose anchor is named.
do
    local savedSprite = getSprite
    -- _0 and _1 are two facings of one fixture, each naming the other.
    getSprite = function(name)
        local offsets = {fixture_01_0 = {Soffset = "1"}, fixture_01_1 = {Noffset = "-1"}}
        local mine = offsets[name]
        if not mine then
            return nil
        end
        return {
            getProperties = function()
                return {
                    has = function(_, key) return mine[key] ~= nil end,
                    get = function(_, key) return mine[key] end
                }
            end
        }
    end

    room("t.hub")
    Core.registerObjects({
        id = "t.fixtures",
        sprites = {"fixture_01_0", "bed_01_0"},
        rooms = {"t.hub"}
    })

    local facingNorth = fakeObject("fixture_01_0", nil)
    local facingSouth = fakeObject("fixture_01_1", nil)
    r.check("a bound sprite reaches its room", Core.roomsForObject(facingNorth)[1], "t.hub")
    r.check("another facing of a bound sprite reaches it too", Core.roomsForObject(facingSouth)[1], "t.hub")
    r.check("an unbound sprite still reaches nothing", #Core.roomsForObject(plain), 0)
    r.check("sprite case does not matter",
        Core.roomsForObject(fakeObject("FIXTURE_01_0", nil))[1], "t.hub")

    -- A bed: the clicked tile is bed_01_3, its grid's anchor is bed_01_0.
    local bedGrid = {
        getAnchorSprite = function() return fakeSprite("bed_01_0", nil) end
    }
    local bedTile = fakeObject("bed_01_3", nil, bedGrid)
    r.check("any tile of a multi-tile object reaches through its anchor",
        Core.roomsForObject(bedTile)[1], "t.hub")
    r.check("tiles of an itemless object share the anchor as identity",
        Core.holderIdentity(bedTile), "bed_01_0")
    r.check("a single itemless tile is identified by its own sprite",
        Core.holderIdentity(facingNorth), "fixture_01_0")
    r.check("an item still wins as identity", Core.holderIdentity(green), "Base.TentGreen")

    r.check("each sprite counts once toward specificity", Core.servingCount("t.hub"), 2)
    r.check("the room lists its sprites", #Core.roomScripts["t.hub"].sprites, 2)

    -- Permanent is a binding's answer, so every object it matches agrees.
    r.check("nothing is permanent while no binding says so", Core.objectIsPermanent(facingNorth), false)
    Core.registerObjects({
        id = "t.fixed",
        sprites = {"fixture_01_0"},
        rooms = {"t.hub"},
        permanent = true
    })
    r.check("a permanent binding nails its object down", Core.objectIsPermanent(facingNorth), true)
    r.check("in every facing", Core.objectIsPermanent(facingSouth), true)
    r.check("but not what it does not match", Core.objectIsPermanent(bedTile), false)
    r.check("nor a tent bound elsewhere", Core.objectIsPermanent(green), false)
    local square = {
        getObjects = function()
            return {
                size = function() return 2 end,
                get = function(_, i) return i == 0 and plain or facingSouth end
            }
        end
    }
    r.check("the square guard finds it among other objects", Core.permanentObjectOn(square), facingSouth)
    Core.bindings["t.fixed"] = nil
    Core.markRegistryDirty()
    r.check("and lets it go when the binding does", Core.permanentObjectOn(square), nil)

    getSprite = savedSprite
    Core.bindings["t.fixtures"] = nil
    Core.markRegistryDirty()
end

-- Case, because a binding is written by hand and CustomItem comes off a tile.
local shouty = fakeObject("camping_04_100", "BASE.TENTGREEN")
r.check("item lookup is case insensitive", Core.roomsForObject(shouty)[1], "t.tent")

-- Unioned like a script binding: somebody else naming the same item ADDS their
-- rooms rather than taking the tent over.
room("t.other")
Core.registerObjects({
    id = "someoneelse.tents",
    items = {"Base.TentGreen"},
    rooms = {"t.other"}
})
local both = Core.roomsForObject(green)
r.check("a second binding unions in", #both, 2)
r.check("and the first binding still counts", Core.roomsForObject(blue)[1], "t.tent")

-- ---------------------------------------------------------------------------
-- Specificity. Items are counted with scripts, because the question the sort
-- asks is "how many distinct things can reach this room" and an item is one.
-- Counting only scripts would leave every object room tied at zero and the id
-- tiebreak would decide allocation -- which is the starvation the ordering
-- exists to stop, reached from a third direction.
-- ---------------------------------------------------------------------------

room("t.narrow")
room("t.broad")
Core.registerObjects({
    id = "t.narrowb",
    items = {"Base.TentGreen"},
    rooms = {"t.narrow"}
})
Core.registerObjects({
    id = "t.broadb",
    items = {"Base.TentGreen", "Base.TentBlue", "Base.TentBrown"},
    rooms = {"t.broad"}
})

r.check("one item is specificity 1", Core.servingCount("t.narrow"), 1)
r.check("three items is specificity 3", Core.servingCount("t.broad"), 3)

-- And against a vehicle room, because the order is global even though the two
-- never compete for the same slot.
Core.registerVehicles({
    id = "t.vanb",
    scripts = {"Base.StepVan", "Base.Van"},
    rooms = {"t.van"}
})
r.check("scripts still count", Core.servingCount("t.van"), 2)

local narrowFirst = (Core.roomRank["t.narrow"] or 0) < (Core.roomRank["t.van"] or 0)
r.check("the narrower room drains first, whatever kind of holder", narrowFirst, true)

-- A matcher still sorts last, and an object matcher is only offered objects.
room("t.any")
Core.registerObjects({
    id = "t.anyb",
    items = {},
    rooms = {"t.any"},
    match = function(object) return Core.moveableItemOf(object) ~= nil end
})
r.check("a matched room is reachable", Core.roomsForObject(crate)[1], "t.any")
r.check("and a plain object still is not", #Core.roomsForObject(plain), 0)
r.check("a matcher sorts last", (Core.roomRank["t.any"] or 0) > (Core.roomRank["t.broad"] or 0), true)

-- ---------------------------------------------------------------------------
-- The lease id.
--
-- Inside modData.movableData, and that is the whole point of the test: vanilla
-- drops a TOP LEVEL key when a non-thumpable moveable is picked up and keeps
-- only movableData, so a lease id written at the top level survives a tent
-- being picked up by one corner and vanishes when it is picked up by another.
-- ---------------------------------------------------------------------------

local tent = fakeObject("camping_04_100", "Base.TentGreen")

r.check("no id before anybody asks for one", Core.objectId(tent, false), nil)
r.check("and nothing was written", tent:hasModData(), false)

local id = Core.objectId(tent, true)
r.check("an id is minted on demand", type(id), "string")
r.check("it is stored under movableData", tent:getModData().movableData[Core.consts.objectIdKey], id)
r.check("and NOT at the top level", tent:getModData()[Core.consts.objectIdKey], nil)
r.check("the write is transmitted", tent.transmitted, 1)

r.check("a second call returns the same id", Core.objectId(tent, true), id)
r.check("and does not transmit again", tent.transmitted, 1)
r.check("reading without create now finds it", Core.objectId(tent, false), id)

local other = fakeObject("camping_04_100", "Base.TentGreen")
r.check("a different tent gets a different id", Core.objectId(other, true) ~= id, true)

-- ---------------------------------------------------------------------------
-- Holder kinds. Three prefixes, one function, and a vehicle UUID must never
-- be mistaken for either of the other two.
-- ---------------------------------------------------------------------------

r.check("an object lease", Core.holderKind(Core.objectKey("abc")), "object")
r.check("an admin lease", Core.holderKind("admin:bob"), "admin")
r.check("a vehicle lease", Core.holderKind("7f3c-9a21-44de"), "vehicle")
r.check("a nil lease reads as a vehicle", Core.holderKind(nil), "vehicle")
r.check("isAdminLease still agrees", Core.isAdminLease("admin:bob"), true)
r.check("and is not confused by an object", Core.isAdminLease(Core.objectKey("abc")), false)

-- ---------------------------------------------------------------------------
-- The sprite grid, which is how any tile of a tent names one holder square.
-- ---------------------------------------------------------------------------

local function fakeGrid(w, h, levels, px, py, pz)
    return {
        getWidth = function() return w end,
        getHeight = function() return h end,
        getLevels = function() return levels end,
        getAnchorSprite = function() return fakeSprite("camping_04_99", "Base.TentGreen") end,
        getSpriteGridPosX = function() return px end,
        getSpriteGridPosY = function() return py end,
        getSpriteGridPosZ = function() return pz end
    }
end

local function fakeSquare(x, y, z)
    return {
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
        getObjects = function() return nil end
    }
end

-- The two tiles probed in game: camping_04_100 at grid 1,3 and camping_04_103
-- at 1,0, both of one design. Three squares apart in y, so if the anchor
-- arithmetic is right they name origins three apart too.
local tileA = fakeObject("camping_04_100", "Base.TentGreen", fakeGrid(2, 4, 1, 1, 3, 0),
    fakeSquare(10586, 9409, 0))
local tileB = fakeObject("camping_04_103", "Base.TentGreen", fakeGrid(2, 4, 1, 1, 0, 0),
    fakeSquare(10586, 9409, 0))

local a = Core.moveableGrid(tileA)
local b = Core.moveableGrid(tileB)
r.check("a tile three rows down anchors three rows up", a.y, 9406)
r.check("the top tile anchors on its own row", b.y, 9409)
r.check("both anchor in the same column", a.x, b.x)
r.check("the extent is carried through", a.width .. "x" .. a.height, "2x4")

local single = Core.moveableGrid(fakeObject("crate_01_0", "Base.WoodenCrate", nil, fakeSquare(1, 2, 0)))
r.check("a single tile object has no grid", single, nil)

-- ---------------------------------------------------------------------------
-- The pickup lock.
--
-- A tent's lease cannot survive the tent being packed away, so the tent
-- refuses to be packed away while the lease is anybody's. The flag itself is
-- only the client's copy of that answer; what is worth pinning down here is
-- that it lands in the same place the id does, that clearing it really clears
-- it, and that Slots.lockReason answers from the two independent facts rather
-- than from one of them twice.
-- ---------------------------------------------------------------------------

-- Its own item type and its own room, deliberately. The bindings above are
-- rewritten by the specificity tests in between -- t.tent ends up demanding a
-- vehicle -- so borrowing one of them would make this read as a lock failure
-- when it was really an allocation refusal.
room("t.lock")
Core.registerObjects({
    id = "t.locktest",
    items = {"Base.TentLockTest"},
    rooms = {"t.lock"}
})

local locked = fakeObject("camping_04_100", "Base.TentLockTest")
Core.objectId(locked, true)
local writes = locked.transmitted

r.check("a fresh tent is not locked", Core.objectLock(locked), nil)

Core.setObjectLock(locked, "occupied")
r.check("the lock reads back", Core.objectLock(locked), "occupied")
r.check("it lives under movableData", locked:getModData().movableData[Core.consts.objectLockKey], "occupied")
r.check("and NOT at the top level", locked:getModData()[Core.consts.objectLockKey], nil)
r.check("writing it transmitted once", locked.transmitted, writes + 1)

Core.setObjectLock(locked, "occupied")
r.check("re-asserting the same reason is silent", locked.transmitted, writes + 1)

Core.setObjectLock(locked, "contents")
r.check("a different reason replaces it", Core.objectLock(locked), "contents")

Core.setObjectLock(locked, nil)
r.check("and nil clears it", Core.objectLock(locked), nil)
r.check("the id is untouched by any of that", Core.objectId(locked, false) ~= nil, true)

-- lockedObjectOn reads the square, because canPickUpMoveable's multi-sprite
-- branch hands the guard a nil object for some grid members and never a nil
-- square.
local function squareHolding(...)
    local list = {...}
    return {
        getObjects = function()
            return {
                size = function() return #list end,
                get = function(_, i) return list[i + 1] end
            }
        end
    }
end

local bystander = fakeObject("crate_01_0", "Base.WoodenCrate")
r.check("an unlocked square yields nothing", Core.lockedObjectOn(squareHolding(bystander, locked)), nil)

Core.setObjectLock(locked, "contents")
local found, why = Core.lockedObjectOn(squareHolding(bystander, locked))
r.check("a locked tile is found past an unlocked one", found, locked)
r.check("and it says why", why, "contents")
r.check("a nil square is not an error", Core.lockedObjectOn(nil), nil)

-- ---------------------------------------------------------------------------
-- Slots.lockReason: occupied is measured now, contents was banked on the way
-- out. Separate facts, separate answers, and occupied wins because it is the
-- one that strands a person rather than losing a thing.
-- ---------------------------------------------------------------------------

local Slots = require "PhunInteriors/slots"
local tenantKey = Core.objectKey(Core.objectId(locked, true))

r.check("no lease, no reason to refuse", Slots.lockReason(tenantKey), nil)

-- `or {}` so a refusal reports as a run of failures rather than aborting the
-- file on the next index. Which checks fail together is the diagnosis.
local lease = Slots.acquire(tenantKey, locked) or {}
r.check("the tent took a room", lease.room, "t.lock")
r.check("an empty leased room may still be packed away", Slots.lockReason(tenantKey), nil)

lease.contents = 3
r.check("but not once it holds something", Slots.lockReason(tenantKey), "contents")

lease.contents = 0
r.check("emptying it lets the tent go again", Slots.lockReason(tenantKey), nil)

Core.occupants["someone"] = {vehicleId = tenantKey, room = lease.room, index = lease.index}
r.check("somebody inside refuses regardless of contents", Slots.lockReason(tenantKey), "occupied")
lease.contents = 5
r.check("and occupied outranks contents", Slots.lockReason(tenantKey), "occupied")

Core.occupants["someone"] = nil
r.check("they leave and the contents answer returns", Slots.lockReason(tenantKey), "contents")
r.check("a nil key is not an error", Slots.lockReason(nil), nil)
r.check("and somebody else's lease is unaffected", Slots.lockReason("object:nobody"), nil)

os.exit(r.finish("holders") > 0 and 1 or 0)
