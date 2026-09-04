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
--
-- One hook, on showRadialMenu, covers both cases. When the player is not
-- seated that function delegates to showRadialMenuOutside *and that happens
-- inside the call we wrap*, so by the time the base returns the outside menu
-- has been built and displayed and our slice lands on it. Do not also wrap
-- showRadialMenuOutside: it has exactly one caller, that delegation, so a
-- second hook only buys a duplicate slice.
--
-- ISRadialMenu:addSlice forwards to the java object when there is one, which
-- is why adding after the base has displayed the menu works at all, and the
-- menu is a fixed size circle so the centring the base did stays correct.
--
-- Do not gate this on menu:isReallyVisible(). It reads false immediately after
-- addToUIManager inside the same call stack, and gating on it silently removes
-- the slice. Vanilla only ever tests it at the *start* of the next call.
-- ---------------------------------------------------------------------------

-- Our own icon does not exist yet (CLAUDE.md, known gaps #2). getTexture
-- returns nil for a missing file and addSlice hands that straight to Java, so
-- fall back to one the vanilla vehicle menu already uses.
local ENTER_TEXTURE = "media/ui/PhunInteriors_enter.png"
local FALLBACK_TEXTURE = "media/ui/vehicles/vehicle_changeseats.png"

local function enterTexture()
    return getTexture(ENTER_TEXTURE) or getTexture(FALLBACK_TEXTURE)
end

local function onEnter(playerObj, vehicle)
    Client.beginEnter(vehicle)
end

local baseShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(playerObj, ...)
    baseShowRadialMenu(playerObj, ...)

    if not playerObj then
        return
    end

    -- Vanilla's own resolver: seat, then useable, then near. Stopping at
    -- useable misses the vehicle the rest of the menu is about.
    local vehicle = ISVehicleMenu.getVehicleToInteractWith(playerObj)
    if not vehicle or not Core.classForVehicle(vehicle) then
        return
    end

    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then
        return
    end

    menu:addSlice(getText("ContextMenu_PhunInteriors_Enter"), enterTexture(), onEnter, playerObj, vehicle)
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
