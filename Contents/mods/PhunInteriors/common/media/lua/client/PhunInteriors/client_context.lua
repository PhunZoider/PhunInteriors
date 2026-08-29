if isServer() then
    return
end
require "PhunInteriors/client_main"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Menus. Entering is a radial slice on the vehicle, matching how players
-- already interact with vehicles. Leaving is normally positional, so the
-- context option exists as an affordance and a safety net rather than as the
-- primary route out.
-- ---------------------------------------------------------------------------

local baseShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(player, ...)
    baseShowRadialMenu(player, ...)

    if not player then
        return
    end

    local vehicle = player:getVehicle() or player:getUseableVehicle()
    if not vehicle then
        return
    end

    local class = Core.classForVehicle(vehicle)
    if not class then
        return
    end

    local menu = getPlayerRadialMenu(player:getPlayerNum())
    if not menu then
        return
    end

    menu:addSlice(getText("ContextMenu_PhunInteriors_Enter"), getTexture("media/ui/PhunInteriors_enter.png"),
        function()
            Client.beginEnter(vehicle)
        end, player)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then
        return
    end
    if not Client.inside then
        return
    end
    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end
    context:addOption(getText("ContextMenu_PhunInteriors_Leave"), player, function()
        Client.requestLeave()
    end)
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
