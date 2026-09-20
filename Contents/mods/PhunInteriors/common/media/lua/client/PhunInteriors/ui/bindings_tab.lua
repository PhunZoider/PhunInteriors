if isServer() then
    return
end
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local ListPanel = require "PhunInteriors/ui/list_panel"
local State = Core.ui.state

Core.ui.bindings_tab = ListPanel:derive("PhunInteriorsBindingsTab")
local UI = Core.ui.bindings_tab
UI.instances = {}

-- ---------------------------------------------------------------------------
-- Who may lease what.
--
-- A binding names GAME SCRIPTS, not ids of ours, which is what makes this tab
-- worth having: pointing a newly installed vehicle mod at an existing room is
-- one line an admin can write from the script name on the workshop page,
-- without waiting for either author to ship a link. Before this it meant
-- editing defaults.lua, which is generated, and restarting.
--
-- Bindings are replaced WHOLE rather than patched, and that is not laziness: a
-- binding is two lists, and "patch a list" has no good meaning, because an
-- entry removed by omission and a list not mentioned look identical. The
-- registry itself replaces too -- Core.bindings is keyed by id and
-- registerVehicles overwrites -- so whole is also what the underlying call
-- does.
--
-- What is never replaced is somebody else's: the script -> rooms answer is
-- unioned across every binding when the index is built, so adding one here
-- ADDS rooms to a vehicle rather than taking it over from the binding that
-- already covers it.
-- ---------------------------------------------------------------------------

--- Everything on the right hand side of the arrow, named the way a room is
--- named everywhere else.
---
--- A binding carries no label of its own and should not: it is two lists and
--- an arrow, and the human fact about it is which room it points at. So the
--- name is the ROOM's, joined here rather than sent, which keeps this a
--- presentation detail and adds nothing to the payload.
---
--- Falls back to the raw id for a room this client has not been told about --
--- a binding naming a room set whose mod is not installed, or one that has
--- not registered yet. That is the case `Core.unresolvedFor` exists for, and
--- showing the id is what lets an admin see WHICH room is missing.
local function roomsText(binding, labels)
    local parts = {}
    for _, id in ipairs(binding.rooms or {}) do
        table.insert(parts, labels[id] or id)
    end
    if #parts == 0 then
        return getText("IGUI_PhunInteriors_Rooms_Unreachable")
    end
    return table.concat(parts, ", ")
end

--- Everything on the left hand side of the arrow.
local function reachText(binding)
    local parts = {}
    for _, script in ipairs(binding.scripts or {}) do
        table.insert(parts, script)
    end
    for _, item in ipairs(binding.items or {}) do
        table.insert(parts, item)
    end
    if binding.matcher then
        -- A predicate is a Lua function in somebody's file: it cannot be sent,
        -- shown or edited, and it claims an unbounded set. Saying nothing
        -- would draw the binding that claims every StepVan in the game as one
        -- that names no scripts at all.
        table.insert(parts, getText("IGUI_PhunInteriors_Binding_Matcher"))
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
        instance._defKind = "bindings"
        instance:initialise()
        UI.instances[index] = instance
    end
    return instance
end

function UI:createChildren()
    ListPanel.createChildren(self)

    self.list.doDrawItem = ListPanel.defaultDrawRow
    self.list:setOnMouseDoubleClick(self, self.onEditClick)

    -- Room first, then who reaches it, which is the order the binding reads
    -- in: "Van - Mechanic is reached by these five scripts". The id led here
    -- for the same reason it led on the Rooms tab and with the same problem --
    -- `phun.vehicles.` is fourteen characters identical on every row, and what
    -- follows it is the room id over again, so the column said the room's name
    -- twice and in its least readable form.
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Rooms"), 0, {
        field = "rooms",
        color = {0.75, 0.85, 0.75}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Reaches"), 0.24, {field = "reach"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Kind"), 0.58, {
        field = "kind",
        color = {0.7, 0.75, 0.8}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Binding"), 0.68, {
        field = "id",
        color = {0.65, 0.65, 0.65}
    })

    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Edit"), self.onEditClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_New"), self.onNewClick)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Delete"), self.onDeleteClick, true)
end

--- What the filter box searches.
---
--- Both names of the room, because the column now shows the label and an
--- admin who has a room id in hand -- off the console, out of
--- PhunInteriors.json, from another mod's docs -- must still be able to find
--- the binding that names it.
function UI:getFilterText(itemData)
    return table.concat({itemData.id, itemData.reach or "", itemData.rooms or "",
        itemData.roomIds or ""}, " ")
end

function UI:refreshList()
    self:clearList()
    -- id -> label, built once per refresh rather than scanned per binding:
    -- there are 139 bindings against 83 rooms, and State.room is a linear
    -- walk of the room list.
    local labels = {}
    for _, room in ipairs(State.registry and State.registry.rooms or {}) do
        labels[room.id] = room.label
    end
    for _, binding in ipairs(State.registry and State.registry.bindings or {}) do
        self:addListItem(binding.id, {
            key = binding.id,
            id = binding.id,
            kind = binding.kind == "object" and getText("IGUI_PhunInteriors_Kind_Object") or
                getText("IGUI_PhunInteriors_Kind_Vehicle"),
            reach = reachText(binding),
            rooms = roomsText(binding, labels),
            roomIds = table.concat(binding.rooms or {}, " "),
            binding = binding
        })
    end
    self:applySort()
    self:applyFilter()
end

function UI:selectedBinding()
    local row = self:selectedRow()
    return row and row.binding or nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function UI:onEditClick()
    local binding = self:selectedBinding()
    if not binding then
        return
    end
    if binding.matcher then
        -- Editing it would save the two lists and silently drop the predicate,
        -- because the predicate cannot cross the wire. That turns the binding
        -- that claims every StepVan in the game into one that claims nine, and
        -- nothing on screen would say so.
        Core.client.notify({
            text = "IGUI_PhunInteriors_Binding_NoEditMatcher",
            warning = true
        })
        return
    end
    require("PhunInteriors/ui/binding_form").open(self.player, binding.id)
end

function UI:onNewClick()
    require("PhunInteriors/ui/binding_form").open(self.player, nil)
end

function UI:onDeleteClick()
    local binding = self:selectedBinding()
    if not binding then
        return
    end

    local tools = require "PhunInteriors/ui/ui_utils"
    -- Two different warnings, because the outcome differs. A binding somebody
    -- registered in lua comes back on the next boot; one made here is gone for
    -- good once saved. Deliberately no tombstone for the first case: a file
    -- that can permanently disable another mod's binding is a bigger power
    -- than this window should have.
    local text = binding.state == "overridden" and
        getText("IGUI_PhunInteriors_Confirm_DeleteBinding", binding.id) or
        getText("IGUI_PhunInteriors_Confirm_DisableBinding", binding.id)
    tools.confirm(text, function()
        Core.dispatch(Core.commands.editBinding, {binding = binding.id, remove = true})
    end, self)
end

UI.refresh = UI.refreshList

return UI
