if isServer() then
    return
end
require "PhunInteriors/client_main"
require "PhunInteriors/reservoir"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Installing a rain reservoir from the inside of the room.
--
-- The action is the felt cost and the request; the server re-plans, finds the
-- kit in the player's inventory itself, and is the only side that spends it.
-- Same shape as PhunInteriorsEnterAction and for the same reason: the request
-- goes through Core.dispatch, which is already proven over the wire, rather
-- than through a server side complete() that would need this class resolvable
-- by name on a dedicated server.
-- ---------------------------------------------------------------------------

PhunInteriorsReservoirAction = ISBaseTimedAction:derive("PhunInteriorsReservoirAction")

function PhunInteriorsReservoirAction:isValid()
    return self.item ~= nil and self.character:getInventory():containsID(self.item:getID())
end

function PhunInteriorsReservoirAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Mid")
end

function PhunInteriorsReservoirAction:stop()
    ISBaseTimedAction.stop(self)
end

function PhunInteriorsReservoirAction:perform()
    Core.dispatch(Core.commands.installReservoir, {
        id = self.item:getID()
    })
    ISBaseTimedAction.perform(self)
end

function PhunInteriorsReservoirAction:new(character, item)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.item = item
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = character:isTimedActionInstant() and 1 or 300
    return o
end

function Client.beginReservoir(player, kit)
    ISInventoryPaneContextMenu.transferIfNeeded(player, kit)
    ISTimedActionQueue.add(PhunInteriorsReservoirAction:new(player, kit))
end

--- Offer the install on the context menu, if this player has a kit and is
--- standing in a room that could ever take one.
--
-- A room that opted out shows nothing. One that could take a reservoir but
-- cannot right now -- it came with barrels, or has no roof -- shows the option
-- greyed out with the reason, so a player holding a kit is not left guessing.
function Client.reservoirOption(context, player)
    local kit = player:getInventory():getFirstTypeRecurse(Core.consts.reservoirItem)
    if not kit then
        return
    end
    local roomId, index = Core.slotAt(player:getX(), player:getY(), player:getZ())
    local room = roomId and Core.rooms[roomId]
    if not room or room.reservoir == false then
        return
    end

    local option = context:addOption(getText("ContextMenu_PhunInteriors_InstallReservoir"), player,
        Client.beginReservoir, kit)
    local spots, why = Core.reservoirPlan(room, index)
    if not spots then
        option.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = getText(why)
        option.toolTip = tip
    end
end
