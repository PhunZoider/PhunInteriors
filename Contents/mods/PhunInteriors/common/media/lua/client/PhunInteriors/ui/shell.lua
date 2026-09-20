if isServer() then
    return
end
require "ISUI/ISCollapsableWindowJoypad"
require "ISUI/ISTabPanel"
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local ListPanel = require "PhunInteriors/ui/list_panel"
local State = Core.ui.state

-- Required so each panel has registered itself on Core.ui before the first
-- open, whatever order the game happened to load the folder in.
require "PhunInteriors/ui/rooms_tab"
require "PhunInteriors/ui/slots_tab"
require "PhunInteriors/ui/bindings_tab"

-- ---------------------------------------------------------------------------
-- One window for the registry.
--
-- This replaces the old two-list room window, and the reason is arithmetic
-- rather than taste. That window put rooms in the top third and slots in the
-- rest, which was right for two rooms of sixty slots and is wrong for 81 rooms
-- of about a dozen: the long list is now the rooms, and a room's stamps are a
-- detour off it. Splitting them also let the slot payload stop riding on every
-- refresh -- see Core.commands.roomSlots.
--
-- Three tabs, in the order the ideas build: what rooms exist, where each one
-- is stamped, and who may lease it. Bindings last because a binding names a
-- room, so meeting the room first is the order the sentence reads in.
--
-- The window owns the title bar, the position, the close button and the Save
-- row. Each tab owns its own list, filter and buttons, which is what stops
-- this file growing a copy of each.
-- ---------------------------------------------------------------------------

local FONT_SCALE = ListPanel.FONT_SCALE
local PAD = ListPanel.PAD
local BUTTON_HGT = ListPanel.FONT_HGT_SMALL + 6

Core.ui.shell = ISCollapsableWindowJoypad:derive("PhunInteriorsShell")
local Shell = Core.ui.shell

local TABS = {
    {key = "rooms", module = "rooms_tab", label = "IGUI_PhunInteriors_Tab_Rooms"},
    {key = "slots", module = "slots_tab", label = "IGUI_PhunInteriors_Tab_Slots"},
    {key = "bindings", module = "bindings_tab", label = "IGUI_PhunInteriors_Tab_Bindings"}
}

local instance = nil

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Shell:new(x, y, width, height, player)
    local o = ISCollapsableWindowJoypad:new(x, y, width, height, player)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.playerIndex = player:getPlayerNum()
    o.backgroundColor = {r = 0, g = 0, b = 0, a = 0.8}
    o.moveWithMouse = true
    o:setResizable(true)
    o.minimumWidth = math.floor(700 * FONT_SCALE)
    o.minimumHeight = math.floor(420 * FONT_SCALE)
    o:setWantKeyEvents(true)
    o._tabsByKey = {}
    return o
end

function Shell:createChildren()
    ISCollapsableWindowJoypad.createChildren(self)

    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local footer = BUTTON_HGT + PAD * 2

    local tabs = ISTabPanel:new(0, th, self.width, self.height - th - rh - footer)
    tabs:initialise()
    tabs:instantiate()
    tabs:setEqualTabWidth(false)
    tabs.onActivateView = Shell.onActivateView
    tabs.target = self
    self:addChild(tabs)
    self.tabs = tabs

    -- Size each view BEFORE it is added. A view builds its children when the
    -- tab panel instantiates it, and building them against the placeholder
    -- size a panel was created at puts the button bar off the bottom edge
    -- until the first prerender.
    local viewW = tabs.width
    local viewH = tabs.height - tabs.tabHeight

    for _, spec in ipairs(TABS) do
        local module = Core.ui[spec.module]
        if module and module.createTab then
            local view = module.createTab(self.player)
            if view then
                view:setShell(self)
                view:setWidth(viewW)
                view:setHeight(viewH)
                tabs:addView(getText(spec.label), view)
                self._tabsByKey[spec.key] = {id = #tabs.viewList, view = view}
            end
        end
    end

    self:buildFooter()
    self:layoutViews()
    self:refresh()
end

--- The Save row, which belongs to the window rather than to a tab.
---
--- There is no autosave, and that is deliberate. An edit applies to the live
--- registry the moment it is made, because standing in the room you just
--- changed is the loop this window exists for -- but it reaches the file only
--- when somebody says so. A mistake still in memory is undone by Revert or by
--- a restart; a mistake already on disk has to be undone by hand.
function Shell:buildFooter()
    local y = self.height - self:resizeWidgetHeight() - BUTTON_HGT - PAD

    local function button(x, label, handler)
        local w = math.max(math.floor(80 * FONT_SCALE),
            getTextManager():MeasureStringX(UIFont.Small, label) + PAD * 2)
        local btn = ISButton:new(x, y, w, BUTTON_HGT, label, self, handler)
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)
        return btn
    end

    self._saveBtn = button(PAD, getText("IGUI_PhunInteriors_Btn_Save"), Shell.onSave)
    self._saveBtn.tooltip = getText("IGUI_PhunInteriors_Tip_Save")
    -- Green, because it is the one button here that commits. Everything else
    -- in the row either reads or throws away, and an admin who has been
    -- editing for ten minutes should be able to find the one that keeps it
    -- without reading the labels.
    --
    -- Both colours are set: ISButton draws backgroundColor when disabled and
    -- backgroundColorMouseOver on hover, so setting one leaves the other at
    -- the default grey and the button changes colour as the pointer crosses
    -- it for no reason the viewer can attribute to anything.
    self._saveBtn.backgroundColor = {r = 0.25, g = 0.55, b = 0.30, a = 0.9}
    self._saveBtn.backgroundColorMouseOver = {r = 0.35, g = 0.70, b = 0.40, a = 1}

    local x = PAD + self._saveBtn:getWidth() + PAD
    self._discardBtn = button(x, getText("IGUI_PhunInteriors_Btn_Discard"), Shell.onDiscard)
    self._discardBtn.tooltip = getText("IGUI_PhunInteriors_Tip_Discard")

    x = x + self._discardBtn:getWidth() + PAD
    self._refreshBtn = button(x, getText("IGUI_PhunInteriors_Btn_Refresh"), Shell.onRefresh)
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

--- Size every view, not just the visible one. ISTabPanel only positions a view
--- when it is added, so a tab switched to after a resize would otherwise
--- appear at the old size for a frame.
function Shell:layoutViews()
    if not self.tabs then
        return
    end
    local w = self.tabs.width
    local h = self.tabs.height - self.tabs.tabHeight
    for _, entry in ipairs(self.tabs.viewList) do
        local view = entry.view
        view:setX(0)
        view:setY(self.tabs.tabHeight)
        view:setWidth(w)
        view:setHeight(h)
    end
end

function Shell:prerender()
    ISCollapsableWindowJoypad.prerender(self)

    -- Nothing to lay out while the window is rolled up to its title bar, and
    -- the arithmetic below would go negative if we tried.
    if not self.tabs or self.isCollapsed then
        return
    end

    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local footer = BUTTON_HGT + PAD * 2
    local w = self.width
    local h = math.max(self.tabs.tabHeight, self.height - th - rh - footer)

    if self.tabs.width ~= w or self.tabs.height ~= h then
        self.tabs:setY(th)
        self.tabs:setWidth(w)
        self.tabs:setHeight(h)
        self:layoutViews()
        local y = self.height - rh - BUTTON_HGT - PAD
        self._saveBtn:setY(y)
        self._discardBtn:setY(y)
        self._refreshBtn:setY(y)
    end

    -- Save says whether there is anything to save, and the count is the honest
    -- version of that: "Save (3)" is a question an admin can answer, where a
    -- permanently enabled button is one they have to remember the state of.
    local unsaved = State.registry and State.registry.unsaved
    self._saveBtn:setEnable(unsaved == true)
    self._discardBtn:setEnable(unsaved == true)

    -- The last thing the server said, then the unsaved marker once it has
    -- faded. One line shared between them rather than two, because they sit in
    -- the same place and the message is always about the edit that caused the
    -- unsaved state -- showing both would say one thing twice.
    local textY = self.height - rh - BUTTON_HGT - PAD + 2
    local textX = self._refreshBtn:getX() + self._refreshBtn:getWidth() + PAD
    if self._status and self._statusUntil and getTimestampMs() < self._statusUntil then
        self:drawText(self._status, textX, textY, 0.75, 0.85, 0.75, 1, UIFont.Small)
    elseif unsaved then
        self:drawText(getText("IGUI_PhunInteriors_Lbl_Unsaved"), textX, textY,
            0.95, 0.85, 0.45, 1, UIFont.Small)
    end
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

--- Refresh on arrival rather than continuously, so a background tab is off the
--- refresh path entirely and has to catch up when it comes forward.
function Shell.onActivateView(self, tabPanel)
    local view = tabPanel:getActiveView()
    if view and view.refresh then
        view:refresh()
    end
end

function Shell:activateTab(key)
    local entry = key and self._tabsByKey[key]
    if not entry then
        return nil
    end
    if self.tabs:getActiveView() ~= entry.view then
        self.tabs:activateViewById(entry.id)
    elseif entry.view.refresh then
        entry.view:refresh()
    end
    return entry.view
end

--- Point the Slots tab at a room and bring it forward.
function Shell:showSlotsFor(roomId)
    local entry = self._tabsByKey.slots
    if not entry then
        return
    end
    -- Told which room BEFORE the tab is activated, because activating it fires
    -- onActivateView, which refreshes -- and a refresh against the old room
    -- would draw the previous room's slots for a frame.
    entry.view:showRoom(roomId)
    self:activateTab("slots")
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Shell:refresh()
    Core.dispatch(Core.commands.rooms, {})
end

Shell.onRefresh = Shell.refresh

function Shell:onSave()
    Core.admin("save", {})
end

function Shell:onDiscard()
    local tools = require "PhunInteriors/ui/ui_utils"
    tools.confirm(getText("IGUI_PhunInteriors_Confirm_Discard"), function()
        Core.admin("revertAll", {})
    end, self)
end

--- Say what the server said about the last action, and go and re-read.
---
--- Admin results otherwise only reach the log, which is the right place for
--- them when the console asked and the wrong place when somebody clicked a
--- button and is looking at a window. One line: they are written to be read as
--- a paragraph in a log, and there is one line here to say it in.
---
--- The refresh is here rather than at each call site on purpose. Every edit
--- ends in one of these, so refreshing on the answer means no action has to
--- remember to -- and asking twice would race the write.
function Shell:notice(text)
    self._status = text
    self._statusUntil = getTimestampMs() + 8000
    self:refresh()
end

--- Shut the window, asking first if there is anything unwritten.
---
--- Worth a prompt because the loss is silent and total: an edit applies to the
--- live registry immediately, so the room LOOKS changed right up until the
--- server restarts and every unsaved patch is gone. Nothing else in the window
--- would have told them.
---
--- The confirm has to re-enter close(), so `_closing` is what stops the prompt
--- asking about itself. A flag rather than a second "reallyClose" method,
--- because the close button, the X, Escape and a joypad B all arrive here and
--- only one of them would have been wired to the other name.
function Shell:close()
    if Core.ui.state.registry and Core.ui.state.registry.unsaved and not self._closing then
        local tools = require "PhunInteriors/ui/ui_utils"
        tools.confirm(getText("IGUI_PhunInteriors_Confirm_CloseUnsaved"), function()
            self._closing = true
            self:close()
        end, self)
        return
    end

    instance = nil
    self:removeFromUIManager()
    ISCollapsableWindowJoypad.close(self)
end

---------------------------------------------------------------------------
-- The single way in
---------------------------------------------------------------------------

function Shell.open(player)
    player = player or getPlayer()
    if not player then
        return nil
    end
    if instance then
        instance:setVisible(true)
        instance:bringToTop()
        instance:refresh()
        return instance
    end

    local width = math.floor(880 * FONT_SCALE)
    local height = math.floor(520 * FONT_SCALE)
    instance = Shell:new((getCore():getScreenWidth() - width) / 2,
        (getCore():getScreenHeight() - height) / 2, width, height, player)
    instance:initialise()
    instance:instantiate()
    instance:setTitle(getText("IGUI_PhunInteriors_Rooms_Title"))
    instance:addToUIManager()
    return instance
end

function Shell.current()
    return instance
end

return Shell
