if isServer() then
    return
end
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local FormPanel = require "PhunInteriors/ui/form_panel"
local State = Core.ui.state

local BindingForm = {}
Core.ui.binding_form = BindingForm

-- ---------------------------------------------------------------------------
-- A binding: which game scripts, or which moveable items, reach which rooms.
--
-- Three list fields rather than three text boxes, because every entry is one
-- exact string out of somebody else's mod and a comma separated box is how a
-- stray space becomes a script nothing matches. A list also makes the
-- one-per-line reality of the data visible.
--
-- The rooms list picks from rooms that EXIST, and the server refuses a binding
-- naming one that does not. That refusal matters: roomsForVehicle drops an
-- unknown room id silently with a `Core.rooms[roomId]` test, so an unchecked
-- binding would save, reload and reach nothing at all, with this window
-- showing it as bound the whole time.
--
-- Scripts are typed rather than picked. There is no list of every vehicle
-- script in the game reachable from here -- and the ones worth binding are
-- precisely the ones from a mod just installed, which is a name read off a
-- workshop page. The hint says which spelling: getFullName, so "Base.StepVan"
-- rather than "StepVan".
-- ---------------------------------------------------------------------------

local KINDS = {"vehicle", "object"}

--- A text-entry modal for adding one string to a list field.
---
--- ISTextBox rather than a second FormPanel: one field with OK and Cancel is
--- what it is, and a form would bring sections, validation rows and a footer
--- for it.
local function askFor(owner, title, onOk)
    local width = math.floor(340 * FormPanel.FONT_SCALE)
    local modal = ISTextBox:new(
        (getCore():getScreenWidth() - width) / 2,
        (getCore():getScreenHeight() - 180) / 2,
        width, 180, title, "", owner,
        function(_, button, _)
            if button.internal == "OK" then
                local text = button.parent.entry:getText()
                if text and text ~= "" then
                    -- Trimmed here rather than on the server, so the row the
                    -- admin sees added is the string that will be stored. A
                    -- trailing space on a script name matches nothing and is
                    -- invisible in a list.
                    onOk((text:gsub("^%s+", ""):gsub("%s+$", "")))
                end
            end
        end)
    modal:initialise()
    modal:addToUIManager()
    return modal
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

--- Edit `bindingId`, or create one when it is nil.
function BindingForm.open(player, bindingId)
    local binding = bindingId and State.binding(bindingId) or nil
    local creating = binding == nil

    if bindingId and not binding then
        return nil
    end

    -- Copies, not the cached tables. A list field mutates what it is given as
    -- the admin adds and removes rows, and writing through into State.registry
    -- would leave the list showing edits that were never applied -- and
    -- surviving a Cancel.
    local scripts = {}
    for _, name in ipairs(binding and binding.scripts or {}) do
        table.insert(scripts, name)
    end
    local items = {}
    for _, name in ipairs(binding and binding.items or {}) do
        table.insert(items, name)
    end
    local rooms = {}
    for _, name in ipairs(binding and binding.rooms or {}) do
        table.insert(rooms, name)
    end

    local form
    form = FormPanel:new({
        title = creating and getText("IGUI_PhunInteriors_Form_NewBinding") or
            getText("IGUI_PhunInteriors_Form_EditBinding", bindingId),
        width = math.floor(440 * FormPanel.FONT_SCALE),
        onApply = function(f)
            BindingForm.apply(bindingId, f, scripts, items, rooms)
        end
    })
    -- FormPanel takes no player, and ISContextMenu.get needs a player NUMBER
    -- rather than a player: on a split screen the menu opens on whichever half
    -- it is told, so defaulting to 0 would put the room picker on the first
    -- player's screen whoever opened it.
    form.playerIndex = player and player:getPlayerNum() or 0

    if creating then
        form:addTextField("id", getText("IGUI_PhunInteriors_Fld_BindingId"), {
            hint = getText("IGUI_PhunInteriors_Hint_BindingId"),
            required = true
        })
    end

    -- Which register call this becomes, and it is not cosmetic: the kind is
    -- what decides whose `match` predicate is shown what. Before bindings
    -- carried one, roomsForVehicle ran every binding's matcher, so an object
    -- predicate written to read a sprite was handed a BaseVehicle.
    form:addComboField("kind", getText("IGUI_PhunInteriors_Fld_Kind"), {
        options = KINDS,
        selected = (binding and binding.kind == "object") and 2 or 1,
        hint = getText("IGUI_PhunInteriors_Hint_Kind"),
        onChange = function()
            local isObject = form:getFieldValue("kind") == "object"
            form:setFieldVisible("scripts", not isObject)
            form:setFieldVisible("items", isObject)
        end
    })

    form:addListField("scripts", getText("IGUI_PhunInteriors_Fld_Scripts"), {
        items = scripts,
        rows = 5,
        hint = getText("IGUI_PhunInteriors_Hint_Scripts"),
        conditional = true,
        onAdd = function()
            askFor(form, getText("IGUI_PhunInteriors_Ask_Script"), function(text)
                table.insert(scripts, text)
                form:setListItems("scripts", scripts)
            end)
        end,
        onRemove = function(_, index)
            table.remove(scripts, index)
            form:setListItems("scripts", scripts)
        end
    })

    form:addListField("items", getText("IGUI_PhunInteriors_Fld_Items"), {
        items = items,
        rows = 5,
        hint = getText("IGUI_PhunInteriors_Hint_Items"),
        conditional = true,
        onAdd = function()
            askFor(form, getText("IGUI_PhunInteriors_Ask_Item"), function(text)
                table.insert(items, text)
                form:setListItems("items", items)
            end)
        end,
        onRemove = function(_, index)
            table.remove(items, index)
            form:setListItems("items", items)
        end
    })

    form:addListField("rooms", getText("IGUI_PhunInteriors_Fld_Rooms"), {
        items = rooms,
        rows = 6,
        hint = getText("IGUI_PhunInteriors_Hint_BindingRooms"),
        required = true,
        onAdd = function()
            BindingForm.pickRoom(form, function(id)
                for _, existing in ipairs(rooms) do
                    if existing == id then
                        return
                    end
                end
                table.insert(rooms, id)
                form:setListItems("rooms", rooms)
            end)
        end,
        onRemove = function(_, index)
            table.remove(rooms, index)
            form:setListItems("rooms", rooms)
        end
    })

    form:initialise()
    local isObject = (binding and binding.kind == "object") or false
    form:setFieldVisible("scripts", not isObject)
    form:setFieldVisible("items", isObject)
    form:addToUIManager()
    form:bringToTop()
    return form
end

--- A menu of the rooms that actually exist.
---
--- Picked rather than typed, unlike the script names above, and the asymmetry
--- is the point: a room id is ours and is knowable here, so there is no excuse
--- for letting somebody type one that does not resolve.
function BindingForm.pickRoom(owner, onPick)
    local options = {}
    for _, room in ipairs(State.registry and State.registry.rooms or {}) do
        table.insert(options, room.id)
    end
    if #options == 0 then
        return
    end

    local menu = ISContextMenu.get(owner.playerIndex or 0,
        getMouseX(), getMouseY())
    for _, id in ipairs(options) do
        menu:addOption(id, nil, function()
            onPick(id)
        end)
    end
    return menu
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

--- Takes the FORM, not a values table: FormPanel calls onApply as
--- `self._onApply(self)`. Reading it as values gave nil for every field, which
--- here meant a binding always saved as kind "vehicle" whatever the combo said
--- -- so an object binding made in the window would have been registered
--- through registerVehicles and reached by no tent.
function BindingForm.apply(bindingId, form, scripts, items, rooms)
    local id = bindingId or (form:getFieldValue("id") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not id or id == "" then
        return
    end
    if #rooms == 0 then
        Core.client.notify({
            text = "IGUI_PhunInteriors_Binding_NeedsRoom",
            warning = true
        })
        return
    end

    local kind = form:getFieldValue("kind") == "object" and "object" or "vehicle"
    Core.dispatch(Core.commands.editBinding, {
        binding = id,
        kind = kind,
        -- Only the list this kind uses. Sending both would store an items list
        -- on a vehicle binding, which registerVehicles keeps and the
        -- specificity sort then counts -- so a vehicle binding could be
        -- ordered by items no vehicle can ever present.
        scripts = kind == "vehicle" and scripts or nil,
        items = kind == "object" and items or nil,
        rooms = rooms
    })
    form:close()
end

return BindingForm
