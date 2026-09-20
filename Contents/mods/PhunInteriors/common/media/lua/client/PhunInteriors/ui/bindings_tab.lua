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

    self:addListColumn(getText("IGUI_PhunInteriors_Col_Binding"), 0, {field = "id"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Kind"), 0.26, {
        field = "kind",
        color = {0.7, 0.75, 0.8}
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Reaches"), 0.36, {field = "reach"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Rooms"), 0.68, {
        field = "rooms",
        color = {0.75, 0.85, 0.75}
    })

    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Edit"), self.onEditClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_New"), self.onNewClick)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Delete"), self.onDeleteClick, true)
end

function UI:getFilterText(itemData)
    return table.concat({itemData.id, itemData.reach or "", itemData.rooms or ""}, " ")
end

function UI:refreshList()
    self:clearList()
    for _, binding in ipairs(State.registry and State.registry.bindings or {}) do
        self:addListItem(binding.id, {
            key = binding.id,
            id = binding.id,
            kind = binding.kind == "object" and getText("IGUI_PhunInteriors_Kind_Object") or
                getText("IGUI_PhunInteriors_Kind_Vehicle"),
            reach = reachText(binding),
            rooms = table.concat(binding.rooms or {}, ", "),
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
