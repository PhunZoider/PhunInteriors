if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/reservoir"
local Core = PhunInteriors
local Transit = require "PhunInteriors/transit"
local Rainwater = {}
Core.modules.rainwater = Rainwater

-- ---------------------------------------------------------------------------
-- Putting a reservoir up. Where the barrels go and whether they may is
-- Core.reservoirPlan, shared with the client; this is the half that spends the
-- kit.
--
-- A B42 rain collector is an IsoThumpable carrying a FluidContainer component,
-- and vanilla's own lid toggle (ISOpenCloseLid:complete) builds one with
-- square:addWorkstationEntity(name, sprite). That creates the thumpable,
-- attaches the entity's components, adds it to the square and transmits it.
-- Nothing registers with a global object system -- SRainBarrelSystem refuses
-- every object in B42 -- and the engine fills it with rain while the square is
-- exterior, including while the chunk is unloaded.
--
-- Taking it down is not here. A scrub removes anything its capture did not
-- record, and Manifest.isStructural never records a tagged barrel.
-- ---------------------------------------------------------------------------

local ENTITY = "RainCollectorRound"
local SPRITE = "carpentry_02_122"

local function tell(player, key, warning)
    Core.respond(player, Core.commands.notify, {
        text = key,
        warning = warning
    })
end

--- Install the reservoir from the kit with this item id, in the room this
--- player occupies. Returns true if the kit was spent.
function Rainwater.install(player, itemId)
    local occupancy = Transit.occupancyOf(player)
    local room = occupancy and Core.rooms[occupancy.room]
    if not room then
        tell(player, "IGUI_PhunInteriors_ReservoirNotInside", true)
        return false
    end

    local item = itemId and player:getInventory():getItemById(itemId)
    if not item or item:getFullType() ~= Core.consts.reservoirItem then
        tell(player, "IGUI_PhunInteriors_ReservoirNoKit", true)
        return false
    end

    local spots, why = Core.reservoirPlan(room, occupancy.index)
    if not spots then
        tell(player, why, true)
        return false
    end

    local cell = getCell()
    local placed = 0
    for _, spot in ipairs(spots) do
        local square = cell:getGridSquare(spot.x, spot.y, spot.z)
        local barrel = square and square:addWorkstationEntity(ENTITY, SPRITE)
        if barrel then
            barrel:getModData()[Core.consts.reservoirKey] = true
            barrel:transmitModData()
            placed = placed + 1
        end
    end

    -- The kit is only spent if something went up. The plan already vetted
    -- every square, so nothing placing means the entity itself would not
    -- build, which is a fault to log rather than a cost to the player.
    if placed == 0 then
        Core.logLn("could not build a " .. ENTITY .. " in " .. occupancy.room .. "#" .. tostring(occupancy.index))
        tell(player, "IGUI_PhunInteriors_ReservoirNoRoof", true)
        return false
    end

    -- ISBBQAddFuel:complete's recipe, but from whichever container the kit is
    -- in rather than assuming the main inventory.
    local container = item:getContainer()
    player:removeFromHands(item)
    container:Remove(item)
    sendRemoveItemFromContainer(container, item)

    Core.logLn(tostring(Core.playerKey(player)) .. " installed a reservoir in " .. occupancy.room .. "#" ..
                   tostring(occupancy.index) .. " (" .. placed .. " of " .. #spots .. " barrels)")
    tell(player, "IGUI_PhunInteriors_ReservoirInstalled", false)
    return true
end

--- Swap one collector the map placed for one plumbing can see.
--
-- ISOpenCloseLid:complete's recipe: copy the water out, take the old object
-- off the square, build the entity in its place and pour the water back. The
-- sprite is unchanged, so the slot's manifest still describes the room and a
-- scrub keeps the new object as the one it expected.
local function rebuild(square, object, entity, sprite)
    local water = object:getFluidContainer()
    water = water and water:copy()
    square:transmitRemoveItemFromSquare(object)
    square:RemoveTileObject(object)

    local barrel = square:addWorkstationEntity(entity, sprite)
    if barrel and water and barrel:getFluidContainer() then
        barrel:getFluidContainer():copyFluidsFrom(water)
    end
    if water then
        FluidContainer.DisposeContainer(water)
    end
    if barrel then
        barrel:sync()
    end
    return barrel ~= nil
end

--- Make every rain collector on this slot's roof one a sink can be plumbed to.
--
-- The map's own barrels load as plain IsoObjects -- see
-- Core.isPlumbableCollector -- so a sink beneath one is never offered Plumb,
-- and one a player re-places to force the option is plumbed to nothing. The
-- lotpack cannot say IsoThumpable, so the fix is here rather than on the map.
--
-- Over the FOOTPRINT, one level up, which is every square the 3x3 search from
-- any floor square can reach. Runs with the room's chunk loaded, which means
-- from the leash. Returns how many were rebuilt.
function Rainwater.rebuildCollectors(roomId, index)
    local bounds = Core.slotBounds(Core.rooms[roomId], index)
    if not bounds then
        return 0
    end
    local cell = getCell()
    local above = bounds.z + 1
    local rebuilt = 0
    for x = bounds.x1, bounds.x2 do
        for y = bounds.y1, bounds.y2 do
            local square = cell:getGridSquare(x, y, above)
            if square then
                local objects = square:getObjects()
                for i = objects:size() - 1, 0, -1 do
                    local object = objects:get(i)
                    local sprite = object and object:getSprite()
                    local name = sprite and sprite:getName()
                    local entity = Core.rainCollectorEntity(name)
                    if entity and not Core.isPlumbableCollector(object) and rebuild(square, object, entity, name) then
                        rebuilt = rebuilt + 1
                    end
                end
            end
        end
    end
    if rebuilt > 0 then
        Core.logLn("rebuilt " .. rebuilt .. " map rain collector(s) on " .. tostring(roomId) .. "#" .. tostring(index) ..
                       " so they can be plumbed")
    end
    return rebuilt
end

return Rainwater
