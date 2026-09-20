require "PhunInteriors/registry"
require "PhunInteriors/bounds"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The rain reservoir: round rain collectors on the roof, put up from a kit.
--
-- A barrel on the roof is only worth having because of plumbing, and vanilla
-- plumbing looks exactly one level up. IsoObject.FindExternalWaterSource tries
-- the square directly above the fixture, then the other eight squares of the
-- 3x3 around it, at z + 1 and nowhere else. So a barrel on every third square
-- reaches every square of the floor below: a 3x4 room needs two and a 3x13
-- five, where one per square would be twelve and thirty-nine at 600 units
-- apiece, from one item.
--
-- Everything here reads squares, so it runs on both sides: the client to
-- decide whether and how to offer the option, the server to decide for real.
-- ---------------------------------------------------------------------------

-- Every sprite vanilla's rain collectors use -- crate and round, open, closed
-- and tarped. Matched by NAME as well as by behaviour, because a barrel the map
-- author painted on may have loaded as a plain IsoObject with no fluid
-- container behind it, and it still means the room came with water.
local RAIN_SPRITES = {
    carpentry_02_54 = true,
    carpentry_02_120 = true,
    carpentry_02_122 = true,
    carpentry_02_124 = true,
    carpentry_02_126 = true,
    carpentry_02_127 = true
}

--- Positions along one axis such that every square from first to last is
--- within one of a position.
local function cover(first, last)
    local points = {}
    local at = first + 1
    while true do
        local point = math.min(at, last)
        table.insert(points, point)
        if point + 1 >= last then
            break
        end
        at = at + 3
    end
    return points
end

--- Where a reservoir's barrels would stand in this slot, or nil if the room
--- takes none.
--
-- Over the FLOOR, not the footprint: the footprint's last row and column are
-- beyond the south and east walls, and a barrel there reaches squares nobody
-- can stand on while missing ones they can.
function Core.reservoirSpots(room, index)
    if not room or room.reservoir == false then
        return nil
    end
    local floor = Core.slotFloor(room, index)
    if not floor then
        return nil
    end
    local spots = {}
    for _, x in ipairs(cover(floor.x1, floor.x2)) do
        for _, y in ipairs(cover(floor.y1, floor.y2)) do
            table.insert(spots, {
                x = x,
                y = y,
                z = floor.z + 1
            })
        end
    end
    return spots
end

--- Is this object a rain collector, or anything else plumbing would draw from?
--
-- The second half is the test FindWaterSourceOnSquare makes -- a thumpable
-- with fluid capacity that is not itself plumbed -- so "already has water" means
-- what the plumbing will actually see.
function Core.isRainCollector(object)
    if not object then
        return false
    end
    local sprite = object:getSprite()
    local name = sprite and sprite:getName()
    if name and RAIN_SPRITES[name] then
        return true
    end
    return instanceof(object, "IsoThumpable") and not object:getUsesExternalWaterSource() and
               (object:getFluidCapacity() or 0) > 0
end

--- Something on the square a barrel would be standing in.
local function blocked(square)
    local floor = square:getFloor()
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and object ~= floor then
            local sprite = object:getSprite()
            local props = sprite and sprite:getProperties()
            if props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)) then
                return true
            end
        end
    end
    return false
end

--- Is this point on the floor level of some other slot?
--
-- Nothing on the shipped map stacks rooms, but a third party pack may, and
-- the level above one room is then the floor of the next.
local function onAnotherRoom(x, y, z)
    for _, candidate in ipairs(Core.slotCandidates(x, y) or {}) do
        if Core.inBounds(candidate.bounds, x, y, z) then
            return true
        end
    end
    return false
end

--- Can a reservoir go up in this slot right now?
--
-- Returns the spots, or nil plus a translation key saying why not. Needs the
-- chunk loaded, which it is whenever anybody is standing in the room.
--
-- An existing collector is looked for first, and over the whole footprint
-- rather than only the spots, so a room that came with barrels says so rather
-- than complaining about its roof. On this map those are real: the barrel
-- variants carry one on every square above the floor, and in 88,49 and 90,49
-- they stand on no roof at all.
--
-- There is no partial install. Every spot must take a barrel, or a room would
-- be left with a corner the plumbing cannot reach and a kit already spent. A
-- room with no roof refuses rather than being given one: a floor built at
-- z + 1 changes the room's light and rain, and whether a square made at
-- runtime counts as outdoors is unconfirmed.
function Core.reservoirPlan(room, index)
    if not room or room.reservoir == false then
        return nil, "IGUI_PhunInteriors_ReservoirNotHere"
    end
    local spots = Core.reservoirSpots(room, index)
    local bounds = Core.slotBounds(room, index)
    if not spots or not bounds then
        return nil, "IGUI_PhunInteriors_ReservoirNoRoof"
    end

    local cell = getCell()
    local above = bounds.z + 1
    for x = bounds.x1, bounds.x2 do
        for y = bounds.y1, bounds.y2 do
            local square = cell:getGridSquare(x, y, above)
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    if Core.isRainCollector(objects:get(i)) then
                        return nil, "IGUI_PhunInteriors_ReservoirHasOne"
                    end
                end
            end
        end
    end

    for _, spot in ipairs(spots) do
        local square = cell:getGridSquare(spot.x, spot.y, spot.z)
        -- isOutside is the exterior flag, which is also the only thing
        -- vanilla's rain collection asks of the square.
        if not square or not square:getFloor() or not square:isOutside() or blocked(square) or
            onAnotherRoom(spot.x, spot.y, spot.z) then
            return nil, "IGUI_PhunInteriors_ReservoirNoRoof"
        end
    end

    return spots
end

return Core
