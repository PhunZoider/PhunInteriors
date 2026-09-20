if isServer() then
    return
end
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local FormPanel = require "PhunInteriors/ui/form_panel"

local SlotForm = {}
Core.ui.slot_form = SlotForm

-- ---------------------------------------------------------------------------
-- Where one stamp is.
--
-- Three numbers and an index, and the index is read-only when moving an
-- existing slot. That is the whole point of a separate form rather than an
-- editable cell: the index is the identity a lease persists, so changing a
-- stamp's POSITION leaves its lease pointing at the same stamp somewhere new,
-- which is recoverable, while changing its NUMBER re-points the lease at a
-- different stamp, which is not. Add and delete are how a numbering changes,
-- and both are explicit actions on the Slots tab.
--
-- Nothing here checks that the position is on a floor, or inside a cell the
-- map ships, because a client cannot: the chunk is almost certainly not
-- loaded, and a cell that exists is a question about a lotpack. That check is
-- Docs/roomcheck.pl, run against the shipped map, and it is the only thing
-- that compares the registry to the map. An edit made here and saved should be
-- followed by a run of it.
-- ---------------------------------------------------------------------------

--- Move an existing slot, or place a new one when `creating`.
function SlotForm.open(player, roomId, slot, creating)
    if not roomId or not slot then
        return nil
    end

    local here = player and {
        x = math.floor(player:getX()),
        y = math.floor(player:getY()),
        z = math.floor(player:getZ())
    } or {x = 0, y = 0, z = 0}

    -- A new stamp starts where the admin is standing, an existing one starts
    -- where it is. Reading the coordinates off your feet is the same idea the
    -- authoring tool is built on, and it is the only position a client can
    -- name without inventing one.
    local start = creating and here or {x = slot.x or here.x, y = slot.y or here.y, z = slot.z or here.z}

    local form
    form = FormPanel:new({
        title = creating and getText("IGUI_PhunInteriors_Form_AddSlot", roomId) or
            getText("IGUI_PhunInteriors_Form_MoveSlot", slot.index, roomId),
        width = math.floor(360 * FormPanel.FONT_SCALE),
        onApply = function()
            local index = creating and tonumber(form:getFieldValue("index")) or slot.index
            if not index or index < 0 or index ~= math.floor(index) then
                return
            end
            Core.dispatch(Core.commands.editRoom, {
                room = roomId,
                locations = {
                    [tostring(index)] = {
                        tonumber(form:getFieldValue("x")) or 0,
                        tonumber(form:getFieldValue("y")) or 0,
                        tonumber(form:getFieldValue("z")) or 0
                    }
                }
            })
            form:close()
        end
    })

    form:addTextField("index", getText("IGUI_PhunInteriors_Col_Slot"), {
        default = tostring(slot.index),
        numeric = true,
        integer = true,
        min = 0,
        -- Read-only when moving. A slot's number is what its lease names, and
        -- an editable box here is one keystroke away from handing an existing
        -- lease somebody else's room.
        editable = creating == true,
        required = true,
        hint = creating and getText("IGUI_PhunInteriors_Hint_NewSlotIndex") or
            getText("IGUI_PhunInteriors_Hint_SlotIndex")
    })
    form:addTextField("x", getText("IGUI_PhunInteriors_Fld_WorldX"), {
        default = tostring(start.x),
        numeric = true,
        integer = true,
        required = true,
        hint = getText("IGUI_PhunInteriors_Hint_SlotPosition")
    })
    form:addTextField("y", getText("IGUI_PhunInteriors_Fld_WorldY"), {
        default = tostring(start.y),
        numeric = true,
        integer = true,
        required = true
    })
    form:addTextField("z", getText("IGUI_PhunInteriors_Fld_WorldZ"), {
        default = tostring(start.z),
        numeric = true,
        integer = true
    })

    form:initialise()
    form:addToUIManager()
    form:bringToTop()
    return form
end

return SlotForm
