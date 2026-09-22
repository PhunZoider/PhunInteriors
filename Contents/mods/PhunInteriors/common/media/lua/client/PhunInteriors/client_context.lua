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

-- media/textures is the loose-png path a mod is loaded from, the same one item
-- icons use; media/ui is vanilla's own and is served from a texture pack.
-- getTexture returns nil for a missing file.
local ICON_TEXTURE = "media/textures/phuninteriors_enter_icon.png"
local FALLBACK_TEXTURE = "media/ui/vehicles/vehicle_changeseats.png"

--- Our own icon, or nil if the png did not ship.
local function modTexture()
    return getTexture(ICON_TEXTURE)
end

-- A radial slice hands its texture straight to Java, so a nil there is not
-- safe and we fall back to one the vanilla vehicle menu already uses. A
-- context option is the other way round: ISContextMenu draws iconTexture only
-- when it is non-nil, so the icon missing simply means no icon.
local function enterTexture()
    return modTexture() or getTexture(FALLBACK_TEXTURE)
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
    if not vehicle or not Core.vehicleHasRooms(vehicle) then
        return
    end

    local menu = getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then
        return
    end

    menu:addSlice(getText("ContextMenu_PhunInteriors_Enter"), enterTexture(), onEnter, playerObj, vehicle)
end

--- The bound object on the clicked square, if there is one.
--
-- Read client side purely to decide whether to draw the option; the server
-- resolves it again off the square it is sent, and nothing the client decided
-- here is taken on trust.
local function boundObjectIn(worldObjects)
    for _, object in ipairs(worldObjects or {}) do
        if Core.objectHasRooms(object) then
            return object
        end
    end
    return nil
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then
        return
    end
    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end

    -- Entering a world object is a context option rather than a radial slice,
    -- because a tent is a thing on the ground and the radial menu is the
    -- vehicle interaction. Only offered when the player is not already inside
    -- somewhere -- the server refuses either way, but an option that can only
    -- be refused should not be drawn.
    if not Client.inside then
        local object = boundObjectIn(worldObjects)
        local square = object and object:getSquare()
        if square then
            context:addOption(getText("ContextMenu_PhunInteriors_EnterObject"), player, function()
                Client.requestEnterObject(square)
            end)
        end
        return
    end
    -- Not in a room whose only way out is somebody else's decision, such as
    -- a spawn room's picker. The server refuses it too.
    if not Client.noExit then
        local leave = context:addOption(getText("ContextMenu_PhunInteriors_Leave"), player, function()
            Client.requestLeave()
        end)
        leave.iconTexture = modTexture()
    end
    if Client.reservoirOption then
        Client.reservoirOption(context, player)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
