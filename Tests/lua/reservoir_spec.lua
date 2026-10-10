local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/reservoir"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end

local report = stubs.reporter()
local check = report.check

-- Only the geometry is testable here. Whether a roof square exists, is outdoors
-- and has a barrel on it needs an IsoGridSquare, and that belongs in the game.

--- Does every floor square have a spot within one square on both axes? That
--- is exactly the 3x3 FindExternalWaterSource searches one level up.
local function reaches(room, index)
    local floor = Core.slotFloor(room, index)
    local spots = Core.reservoirSpots(room, index)
    for x = floor.x1, floor.x2 do
        for y = floor.y1, floor.y2 do
            local found = false
            for _, spot in ipairs(spots) do
                if math.abs(spot.x - x) <= 1 and math.abs(spot.y - y) <= 1 then
                    found = true
                    break
                end
            end
            if not found then
                return x .. "," .. y
            end
        end
    end
    return "all"
end

--- Is every spot over the floor, one level up?
local function overFloor(room, index)
    local floor = Core.slotFloor(room, index)
    for _, spot in ipairs(Core.reservoirSpots(room, index)) do
        if spot.z ~= floor.z + 1 or spot.x < floor.x1 or spot.x > floor.x2 or spot.y < floor.y1 or spot.y >
            floor.y2 then
            return spot.x .. "," .. spot.y .. "," .. spot.z
        end
    end
    return "all"
end

-- Floor sizes, and how many barrels each should take. The footprint registered
-- is one more each way, as on the shipped map.
local sizes = {
    {w = 1, h = 1, barrels = 1},
    {w = 2, h = 3, barrels = 1},
    {w = 3, h = 3, barrels = 1},
    {w = 3, h = 4, barrels = 2},
    {w = 3, h = 6, barrels = 2},
    {w = 3, h = 9, barrels = 3},
    {w = 3, h = 13, barrels = 5},
    {w = 7, h = 2, barrels = 3},
    {w = 5, h = 15, barrels = 10}
}

for i, size in ipairs(sizes) do
    local id = "r.floor" .. size.w .. "x" .. size.h
    Core.registerRoom(id, {
        size = {w = size.w + 1, h = size.h + 1},
        locations = {[0] = {1000 + i * 40, 1000, 0}}
    })
    local room = Core.rooms[id]
    check(id .. " reaches every floor square", reaches(room, 0), "all")
    check(id .. " stands every barrel over the floor", overFloor(room, 0), "all")
    check(id .. " takes the fewest barrels", #Core.reservoirSpots(room, 0), size.barrels)
end

-- The south and east wall lines are outside the floor. A barrel over them
-- would reach squares nobody stands on; the 3x4 must not use the footprint.
local threeByFour = Core.rooms["r.floor3x4"]
check("3x4 never stands a barrel over the east wall line",
    Core.reservoirSpots(threeByFour, 0)[1].x <= Core.slotFloor(threeByFour, 0).x2, true)

-- On by default, off only when the room says so.
check("a room that says nothing takes a reservoir", Core.rooms["r.floor2x3"].reservoir, true)
Core.registerRoom("r.tent", {
    size = {w = 3, h = 3},
    reservoir = false,
    locations = {[0] = {2000, 1000, 0}}
})
local tent = Core.rooms["r.tent"]
check("reservoir = false is kept", tent.reservoir, false)
check("an opted out room has no spots", Core.reservoirSpots(tent, 0), nil)
check("and plans to say so", select(2, Core.reservoirPlan(tent, 0)), "IGUI_PhunInteriors_ReservoirNotHere")

-- A missing slot is not a room that opted out.
check("a missing slot has no spots", Core.reservoirSpots(threeByFour, 7), nil)
check("and is refused as having no roof", select(2, Core.reservoirPlan(threeByFour, 7)),
    "IGUI_PhunInteriors_ReservoirNoRoof")

-- The stub world has no squares, which is a room with no roof, never a plan.
check("no squares above the room is no roof", select(2, Core.reservoirPlan(threeByFour, 0)),
    "IGUI_PhunInteriors_ReservoirNoRoof")
check("and yields no spots", (Core.reservoirPlan(threeByFour, 0)), nil)

-- Which entity rebuilds a map barrel, and which barrels need it. A map-placed
-- collector is a plain IsoObject that still holds a FluidContainer, and only
-- the thumpable can be plumbed to.
check("the round barrel builds RainCollectorRound", Core.rainCollectorEntity("carpentry_02_122"),
    "RainCollectorRound")
check("a closed tarped barrel keeps its own entity", Core.rainCollectorEntity("carpentry_02_127"),
    "RainCollectorRound_TarpClosed")
check("a sink is not a collector", Core.rainCollectorEntity("fixtures_sinks_01_16"), nil)
check("no sprite is not a collector", Core.rainCollectorEntity(nil), nil)

local savedInstanceof = instanceof
instanceof = function(object, class)
    return object.class == class
end
local fluid = {}
local function barrel(class, container)
    return {
        class = class,
        getFluidContainer = function()
            return container
        end
    }
end
check("a map barrel with water is not plumbable", Core.isPlumbableCollector(barrel("IsoObject", fluid)), false)
check("a thumpable with a container is", Core.isPlumbableCollector(barrel("IsoThumpable", fluid)), true)
check("a thumpable with no container is not", Core.isPlumbableCollector(barrel("IsoThumpable", nil)), false)
instanceof = savedInstanceof

os.exit(report.finish("reservoir") == 0 and 0 or 1)
