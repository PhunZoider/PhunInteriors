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
-- The hook on showRadialMenu covers both cases. When the player is not
-- seated that function delegates to showRadialMenuOutside *and that happens
-- inside the call we wrap*, so by the time the base returns the outside menu
-- has been built and displayed and our slice lands on it.
--
-- showRadialMenuOutside is wrapped as well, for the callers that skip
-- showRadialMenu. In vanilla it has exactly one caller, that delegation, but
-- Project Viewpoint (workshop 3809306528) calls it directly from
-- ViewpointInteract.harvestVehicle, with getPlayerRadialMenu swapped for a
-- stand-in that records each slice, and turns the slices into its own [F]
-- menu. Hooked on showRadialMenu alone, first person had no way in at all.
-- `building` is what stops the vanilla path getting the slice twice: the
-- inner hook stands down while the outer one is on the stack and adds it
-- after the base returns, exactly as before.
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

local function addEnterSlice(playerObj)
    if not playerObj then
        return
    end

    -- Vanilla's own resolver: seat, then useable, then near. Stopping at
    -- useable misses the vehicle the rest of the menu is about. Read off the
    -- table at call time, because Viewpoint swaps it for one that answers
    -- the vehicle its crosshair is on.
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

local building = false

local baseShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(playerObj, ...)
    building = true
    local ok, err = pcall(baseShowRadialMenu, playerObj, ...)
    building = false
    if not ok then
        error(err)
    end
    addEnterSlice(playerObj)
end

local baseShowRadialMenuOutside = ISVehicleMenu.showRadialMenuOutside

function ISVehicleMenu.showRadialMenuOutside(playerObj, ...)
    baseShowRadialMenuOutside(playerObj, ...)
    if not building then
        addEnterSlice(playerObj)
    end
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
    --
    -- Every option here carries the clicked object as a trailing argument
    -- that its handler ignores. Project Viewpoint builds its first person [F]
    -- menu by calling createMenu for the one object under its crosshair and
    -- keeps a top level option only when some argument IS that object
    -- (`whose` in Viewpoint_Interact.lua); an option naming only the player
    -- is dropped as somebody else's. So without it a tent could not be
    -- entered and nobody could step outside in first person.
    local clicked = worldObjects and worldObjects[1]
    if not Client.inside then
        local object = boundObjectIn(worldObjects)
        local square = object and object:getSquare()
        if square then
            context:addOption(getText("ContextMenu_PhunInteriors_EnterObject"), player, function()
                Client.requestEnterObject(square)
            end, object)
        end
        return
    end
    -- Not in a room whose only way out is somebody else's decision, such as
    -- a spawn room's picker. The server refuses it too.
    if not Client.noExit then
        local leave = context:addOption(getText("ContextMenu_PhunInteriors_Leave"), player, function()
            Client.requestLeave()
        end, clicked)
        leave.iconTexture = modTexture()
    end
    if Client.reservoirOption then
        Client.reservoirOption(context, player, clicked)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
