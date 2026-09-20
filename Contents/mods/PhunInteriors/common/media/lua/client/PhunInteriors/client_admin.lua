if isServer() then
    return
end
require "DebugUIs/DebugMenu/ISDebugMenu"
require "PhunInteriors/tools"
require "PhunInteriors/client_main"
require "PhunInteriors/client_rooms"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Where the room list is reached from.
--
-- Two doors, matching what PhunMart2 does and for the same reason: the admin
-- panel is where an admin looks on a server, and the debug menu is where a
-- single player developer looks. Both route through one function so the access
-- rule cannot differ depending on which one somebody happened to use.
--
-- The server re-checks admin rights on every command these send, so this is an
-- entry point and not a gate. What it stops is the window opening for somebody
-- whose every button would then be refused.
-- ---------------------------------------------------------------------------

local function openRooms()
    local player = getPlayer()
    if not player then
        return
    end
    if not Core.tools.isAdmin(player) then
        Client.notify({
            text = "IGUI_PhunInteriors_Rooms_NotAdmin",
            warning = true
        })
        return
    end
    Client.openRooms(player)
end

Client.openRoomsMenu = openRooms

-- Single player, and anyone with debug enabled.
local ISDebugMenu_setupButtons = ISDebugMenu.setupButtons
function ISDebugMenu:setupButtons()
    self:addButtonInfo("PhunInteriors", openRooms, "MAIN")
    ISDebugMenu_setupButtons(self)
end

-- The server admin panel.
--
-- The button is added BEFORE the base runs, which is what puts it in the grid:
-- vanilla's create() lays out every child it finds at the end, sorts them by
-- title and then places the close button beneath the lot. Adding afterwards
-- would leave ours sitting wherever it was put, on top of whatever was there.
local ISAdminPanelUI_create = ISAdminPanelUI.create
function ISAdminPanelUI:create()
    local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
    local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
    local UI_BORDER_SPACING = 10
    local BUTTON_HGT = FONT_HGT_SMALL + 6

    self.phunInteriorsRooms = ISButton:new(UI_BORDER_SPACING + 1,
        FONT_HGT_MEDIUM + UI_BORDER_SPACING * 2 + 1, 200, BUTTON_HGT,
        getText("IGUI_PhunInteriors_Rooms_Title"), self, openRooms)
    self.phunInteriorsRooms.internal = ""
    self.phunInteriorsRooms:initialise()
    self.phunInteriorsRooms:instantiate()
    self.phunInteriorsRooms.borderColor = self.buttonBorderColor
    self:addChild(self.phunInteriorsRooms)

    ISAdminPanelUI_create(self)
end

-- And from the console, for the same reason Core.admin exists.
--
--     PhunInteriors.roomList()
--
-- NOT Core.rooms. That name is the registry table -- core.lua:61 -- and a
-- function here replaced it for every client and every single player session,
-- so the first registerRoom call indexed a function and the mod did not boot.
-- Nothing may be hung off Core under a name core.lua already declares; the
-- collision is silent until something reads the field.
function Core.roomList()
    openRooms()
    return "opening the room list"
end
