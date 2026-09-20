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

return Rainwater
