if isServer() then
    return
end
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local ListPanel = require "PhunInteriors/ui/list_panel"
local State = Core.ui.state

Core.ui.rooms_tab = ListPanel:derive("PhunInteriorsRoomsTab")
local UI = Core.ui.rooms_tab
UI.instances = {}

-- ---------------------------------------------------------------------------
-- Every registered room, one row each.
--
-- This replaces the top half of the old room list window, and the reason it is
-- a separate tab from the slots rather than a pane above them is arithmetic:
-- the shipped map went from 2 rooms of 60 slots to 81 rooms of about 12, so
-- the two lists no longer want a third of the window each. Rooms is now the
-- long list and a room's slots are a detour off it.
--
-- The columns say what the CONTRACT says, because that is what the editor
-- edits. The old window showed slots, free and power; a room now also states
-- which edge faces the holder's nose, whether that edge is a cab, whether its
-- power is free and what it weighs empty -- and every one of those is a field
-- somebody can get wrong in a way that only shows up as a stranded tenant.
-- ---------------------------------------------------------------------------

--- "3x4", from the footprint. Shown rather than the floor, because `size` is
--- what the registration states and what the form edits -- and the difference
--- between the two is exactly the thing that goes wrong (the south and east
--- walls sit outside the floor, so the floor is the box less its last row and
--- column). Labelling this "size" and meaning the footprint keeps the window
--- honest about which number it is.
local function sizeText(room)
    if not room.size then
        return "-"
    end
    return tostring(room.size.w) .. "x" .. tostring(room.size.h)
end

--- Which way out, in one column.
---
--- A room with no front lands its tenant beside the holder, which is a real
--- and deliberate answer rather than a missing one -- four of the shipped
--- rooms say nothing here on purpose. So it reads "beside" rather than "-":
--- a dash invites somebody to fill it in.
local function exitText(room)
    if not room.front then
        return getText("IGUI_PhunInteriors_Exit_Beside")
    end
    if room.cab then
        return getText("IGUI_PhunInteriors_Exit_Cab", room.front)
    end
    return room.front
end

--- Generator, and whether its fuel is free.
---
--- Two facts in one column and deliberately three distinct words, because
--- "powered" already means "has a generator" in this payload and selfPowered
--- means "has a free one". One word for both is how a reader ends up
--- confidently wrong; see registerRoom.
local function powerText(room)
    if not room.powered then
        return getText("IGUI_PhunInteriors_Power_None")
    end
    if room.selfPowered then
        return getText("IGUI_PhunInteriors_Power_Free")
    end
    return getText("IGUI_PhunInteriors_Power_Metered")
end

--- Free slots, with the dirty ones counted separately.
---
--- Quarantined slots ARE free -- they are merely dirty, and they are handed
--- out last and scrubbed on arrival. Counting them as taken reports a room as
--- filling up when nothing is in it.
local function freeText(room)
    local free = room.total - room.leased
    if room.quarantined > 0 then
        return getText("IGUI_PhunInteriors_Rooms_FreeDirty", free, room.quarantined)
    end
    return tostring(free)
end

--- Everything that can reach this room, vehicles and world objects together.
local function reachText(room)
    local parts = {}
    for _, script in ipairs(room.scripts or {}) do
        table.insert(parts, script)
    end
    for _, item in ipairs(room.items or {}) do
        table.insert(parts, item)
    end
    if (room.matchers or 0) > 0 then
        -- A matcher covers an unbounded set, so rendering it as nothing would
        -- say "no vehicle can reach this room" about the room anything can.
        table.insert(parts, getText("IGUI_PhunInteriors_Rooms_Matcher", room.matchers))
    end
    if #parts == 0 then
        return getText("IGUI_PhunInteriors_Rooms_Unreachable")
    end
    return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function UI.createTab(player)
    local index = player:getPlayerNum()
    local instance = UI.instances[index]
    if not instance then
        instance = UI:new(0, 0, 100, 100, player)
        -- What the state stripe down the left of a row asks about. "rooms" is
        -- the kind Core.isShippedKey and Core.isOverriddenKey answer for.
        instance._defKind = "rooms"
        instance:initialise()
        UI.instances[index] = instance
    end
    return instance
end

function UI:createChildren()
    ListPanel.createChildren(self)

    self.list.doDrawItem = ListPanel.defaultDrawRow
    -- Double click is "show me this room's slots", which is the question a row
    -- most often leads to and the one that used to be a second list on screen.
    self.list:setOnMouseDoubleClick(self, self.onSlotsClick)

    self:addListColumn(getText("IGUI_PhunInteriors_Col_Room"), 0, {field = "id"})
    -- The label, and it is here because its absence read as a bug: an admin
    -- who renames a room and sees nothing change in the only list that names
    -- rooms concludes the rename did not take. It is also the only human name
    -- a room has -- "Bus - Military" against `phun.room.Bus_Military_3x9` --
    -- and the id column is sorted by a string most of which is boilerplate.
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Label"), 0.28, {
        field = "label",
        color = {0.85, 0.85, 0.75}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Size"), 0.44, {
        field = "size",
        color = {0.7, 0.75, 0.8}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Slots"), 0.50, {field = "slots"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Free"), 0.56, {field = "free"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Exit"), 0.62, {
        field = "exit",
        color = {0.8, 0.8, 0.65}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Power"), 0.71, {field = "power"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Vehicles"), 0.80, {
        field = "reach",
        color = {0.7, 0.7, 0.7}
    })

    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Enter"), self.onEnterClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Slots"), self.onSlotsClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Edit"), self.onEditClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_New"), self.onNewClick)
    self._revertBtn = self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Revert"),
        self.onRevertClick, true)
end

--- What the filter box searches.
---
--- Id, label, and everything that can reach the room -- because "which room
--- does the mail van get" is asked as often as "show me the bar", and a filter
--- that only read ids would answer neither. Matches Admin.roomMatches on the
--- server, so the console list and this box find the same rooms.
function UI:getFilterText(itemData)
    return table.concat({itemData.id, itemData.label or "", itemData.reach or ""}, " ")
end

function UI:refreshList()
    self:clearList()
    for _, room in ipairs(State.registry and State.registry.rooms or {}) do
        self:addListItem(room.id, {
            key = room.id,
            id = room.id,
            -- Falls back to the id, as registerRoom does, so the column is
            -- never blank for a room whose author never named one.
            label = room.label or room.id,
            size = sizeText(room),
            slots = tostring(room.total),
            free = freeText(room),
            exit = exitText(room),
            power = powerText(room),
            reach = reachText(room),
            room = room
        })
    end
    self:applySort()
    self:applyFilter()
end

--- The room record behind the selected row, or nil.
function UI:selectedRoom()
    local row = self:selectedRow()
    return row and row.room or nil
end

function UI:prerender()
    ListPanel.prerender(self)
    -- Revert is meaningless on a stock room and would be a button that reports
    -- "nothing to do" -- so it is greyed rather than allowed to disappoint.
    if self._revertBtn then
        local room = self:selectedRoom()
        self._revertBtn:setEnable(room ~= nil and room.state ~= "shipped")
    end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function UI:onEnterClick()
    local room = self:selectedRoom()
    if not room then
        return
    end
    -- No index: "whichever slot is next", which is both the common case and
    -- the one that does not need the slot list at all. Slots tab sends one.
    Core.admin("enter", {room = room.id})
end

function UI:onSlotsClick()
    local room = self:selectedRoom()
    if not room or not self.shell then
        return
    end
    self.shell:showSlotsFor(room.id)
end

function UI:onEditClick()
    local room = self:selectedRoom()
    if not room then
        return
    end
    require("PhunInteriors/ui/room_form").open(self.player, room.id)
end

function UI:onNewClick()
    require("PhunInteriors/ui/room_form").open(self.player, nil)
end

function UI:onRevertClick()
    local room = self:selectedRoom()
    if not room or room.state == "shipped" then
        return
    end

    local tools = require "PhunInteriors/ui/ui_utils"
    -- Confirmed, and the two cases say different things. Reverting a patched
    -- room puts the shipped definition back; reverting a room that only ever
    -- existed in the file DELETES it, and a tenant standing in one of its
    -- slots is about to be somewhere that is not a room.
    local text = room.state == "new" and
        getText("IGUI_PhunInteriors_Confirm_DeleteRoom", room.id) or
        getText("IGUI_PhunInteriors_Confirm_RevertRoom", room.id)
    tools.confirm(text, function()
        Core.dispatch(Core.commands.editRoom, {room = room.id, revert = true})
    end, self)
end

--- Re-read whenever a fresh payload lands, which is what the shell's tab
--- switch and the registry event both end up calling.
UI.refresh = UI.refreshList

return UI
