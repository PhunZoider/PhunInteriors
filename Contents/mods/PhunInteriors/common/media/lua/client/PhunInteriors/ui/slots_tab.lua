if isServer() then
    return
end
require "ISUI/ISComboBox"
require "ISUI/ISLabel"
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local ListPanel = require "PhunInteriors/ui/list_panel"
local State = Core.ui.state

Core.ui.slots_tab = ListPanel:derive("PhunInteriorsSlotsTab")
local UI = Core.ui.slots_tab
UI.instances = {}

-- ---------------------------------------------------------------------------
-- One room's stamps.
--
-- A tab rather than a second list under the rooms, because the shipped map is
-- 81 rooms of about a dozen slots and neither list wants a third of the window
-- any more. Slots are fetched when a room is chosen rather than sent with the
-- room list -- 960 slot records crossing sendServerCommand on every refresh,
-- all but one room's worth of it drawn by nothing.
--
-- Which room is chosen two ways: the Rooms tab's Slots button, and the pair of
-- dropdowns at the top of this tab. Both end at showRoom, so the pickers are
-- always showing the room whose slots are on screen whichever route got here.
--
-- The index is the identity a lease persists, so it is the first column and it
-- is never renumbered. Everything that can be done here respects that: a
-- position can be changed, a slot can be added at a new index, and a deleted
-- slot leaves a GAP. Closing the gap up would re-point every lease past the
-- change at somebody else's room.
-- ---------------------------------------------------------------------------

-- A colour per state, so a dozen rows can be read without reading them.
local STATE_COLOURS = {
    free = {0.75, 0.78, 0.75},
    mine = {0.55, 0.85, 0.55},
    leased = {0.95, 0.80, 0.45},
    quarantine = {0.90, 0.55, 0.45},
    -- Not a lease state: a claim is drawn over whatever the lease says,
    -- because it is the fact that changes what the buttons will do.
    claimed = {0.55, 0.70, 0.95}
}

local function stateText(slot)
    if slot.occupied then
        return getText("IGUI_PhunInteriors_State_Occupied")
    end
    if slot.claimedBy then
        -- A claim outranks the lease state in the one column there is, because
        -- it is the fact that changes what the buttons will do: a claimed slot
        -- cannot be reset, scrubbed or reclaimed while the claim stands.
        return getText("IGUI_PhunInteriors_State_Claimed", slot.claimedBy)
    end
    return getText("IGUI_PhunInteriors_State_" ..
        string.upper(string.sub(slot.state, 1, 1)) .. string.sub(slot.state, 2))
end

--- "3.4 days", or how long in whichever unit reads.
---
--- World days, not real ones -- it is measured against the same clock
--- RoomProtectedDays is, so the number here and the number that decides a
--- reclaim are the same number.
local function idleText(slot)
    if slot.state == "free" or slot.state == "quarantine" then
        return ""
    end
    local days = slot.idleDays
    if not days then
        return "-"
    end
    if days < 1 then
        local hours = math.floor(days * 24 + 0.5)
        if hours <= 1 then
            return getText("IGUI_PhunInteriors_Idle_JustNow")
        end
        return getText("IGUI_PhunInteriors_Idle_Hours", hours)
    end
    return getText("IGUI_PhunInteriors_Idle_Days", string.format("%.1f", days))
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function UI.createTab(player)
    local index = player:getPlayerNum()
    local instance = UI.instances[index]
    if not instance then
        instance = UI:new(0, 0, 100, 100, player)
        -- No state stripe: the three states it draws are about a DEFINITION
        -- being stock, modified or custom, and a slot is not a definition. Its
        -- own "has this one been moved" lives in the Edited column, where it
        -- cannot be confused with the room's state.
        instance._defKind = nil
        instance.roomId = nil
        instance:initialise()
        UI.instances[index] = instance
    end
    return instance
end

---------------------------------------------------------------------------
-- The pickers
--
-- Two dropdowns above the list, because reaching this tab used to mean going
-- back to Rooms, finding the row again and pressing Slots -- which is most of
-- the work when the job is walking a set of stamps one room at a time.
--
-- They narrow rather than search: the vehicle picker decides WHICH ROOMS the
-- room picker offers, and the room picker decides whose slots are drawn. That
-- is deliberately a different question from the filter box at the bottom of
-- the panel, which searches WITHIN the slots on screen. Two controls that both
-- said "filter" and meant different things would be worse than either.
--
-- The vehicle one earns its place on this map rather than in the abstract:
-- there are 81 rooms and most are reachable by exactly one script, so "which
-- room does the mail van get" is otherwise a scroll through a list sorted by
-- an id that does not mention the van.
---------------------------------------------------------------------------

local ANY = "IGUI_PhunInteriors_Any"

--- Every script and item that can reach any room, deduped and sorted.
local function allHolders(rooms)
    local seen, out = {}, {}
    for _, room in ipairs(rooms or {}) do
        for _, list in ipairs({room.scripts or {}, room.items or {}, room.sprites or {}}) do
            for _, name in ipairs(list) do
                if not seen[name] then
                    seen[name] = true
                    table.insert(out, name)
                end
            end
        end
    end
    table.sort(out)
    return out
end

--- Can `holder` reach this room? nil means "no holder chosen", which is all of
--- them rather than none -- the picker's first entry is "(any)".
local function roomReaches(room, holder)
    if not holder then
        return true
    end
    for _, list in ipairs({room.scripts or {}, room.items or {}, room.sprites or {}}) do
        for _, name in ipairs(list) do
            if name == holder then
                return true
            end
        end
    end
    return false
end

function UI:createChildren()
    ListPanel.createChildren(self)

    local FONT_HGT = ListPanel.FONT_HGT_SMALL
    local H = FONT_HGT + 6

    self._vehicleLabel = ISLabel:new(0, 0, H, getText("IGUI_PhunInteriors_Lbl_Vehicle"),
        0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self._vehicleLabel:initialise()
    self._mainPanel:addChild(self._vehicleLabel)

    self._vehicleCombo = ISComboBox:new(0, 0, 100, H, self, UI.onPickVehicle)
    self._vehicleCombo:initialise()
    self._vehicleCombo:instantiate()
    self._mainPanel:addChild(self._vehicleCombo)

    self._roomLabel = ISLabel:new(0, 0, H, getText("IGUI_PhunInteriors_Lbl_Room"),
        0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self._roomLabel:initialise()
    self._mainPanel:addChild(self._roomLabel)

    self._roomCombo = ISComboBox:new(0, 0, 100, H, self, UI.onPickRoom)
    self._roomCombo:initialise()
    self._roomCombo:instantiate()
    self._mainPanel:addChild(self._roomCombo)

    self:rebuildPickers()

    self.list.doDrawItem = ListPanel.defaultDrawRow
    self.list:setOnMouseDoubleClick(self, self.onEnterClick)

    self:addListColumn(getText("IGUI_PhunInteriors_Col_Slot"), 0, {field = "index"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Position"), 0.08, {field = "position"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_State"), 0.32, {
        field = "state",
        -- A function rather than a table, because the colour is per ROW here
        -- and a table on the column is one colour for all of them.
        color = function(data)
            local colour = data.stateColour
            if colour then
                return colour[1], colour[2], colour[3]
            end
        end
    })
    -- How long since anybody was in, and who. These replaced showing the
    -- holder -- a 36 character UUID that could not be recognised and answered
    -- a question nobody was asking. "Nobody has been in for eleven days" is
    -- what actually decides whether a slot is worth resetting, and it is the
    -- same measurement a reclaim picks on.
    self:addListColumn(getText("IGUI_PhunInteriors_Col_LastIn"), 0.46, {
        field = "lastIn",
        -- Reddens as it approaches the protection window, so the slots a full
        -- pool would take next stand out without reading the numbers.
        color = function(data)
            if data.idleDays and data.idleDays >= 7 then
                return 0.95, 0.75, 0.45
            end
            return 0.75, 0.75, 0.75
        end
    })
    self:addListColumn(getText("IGUI_PhunInteriors_Col_LastUser"), 0.60, {field = "lastUser"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Blueprint"), 0.76, {field = "captured"})
    self:addListColumn(getText("IGUI_PhunInteriors_Col_Edited"), 0.88, {
        field = "edited",
        color = {0.9, 0.8, 0.5}
    })

    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Enter"),
        self.onEnterClick, true).tooltip = getText("IGUI_PhunInteriors_Tip_Enter")
    -- "Reset", not "Release". Release reads as handing back something the
    -- admin owns, and what this does to a slot is drop whoever holds it and
    -- mark it to be wiped clean when it is next handed out. The server action
    -- is still called `release`, because that is what it does to the LEASE;
    -- the button is named for what it does to the SLOT, which is what an admin
    -- is looking at.
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Reset"),
        self.onReleaseClick, true).tooltip = getText("IGUI_PhunInteriors_Tip_Reset")
    -- The refresh loop for a room that is never handed back, a hub above all:
    -- redecorate it, Recapture to make that the blueprint, and Scrub whenever
    -- it wants putting back to it. Both are the console's remanifest and
    -- scrub, unchanged.
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Recapture"),
        self.onRecaptureClick, true).tooltip = getText("IGUI_PhunInteriors_Tip_Recapture")
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Scrub"),
        self.onScrubClick, true).tooltip = getText("IGUI_PhunInteriors_Tip_Scrub")
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_Move"), self.onMoveClick, true)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_AddSlot"), self.onAddClick)
    self:addBottomButton(getText("IGUI_PhunInteriors_Btn_DeleteSlot"), self.onDeleteClick, true)
end

--- Place the two pickers, and say how much room they took.
---
--- Called by the vendored list panel between the description and the list; see
--- the layoutHeaderRow note there. Both combos share the leftover width so the
--- room ids, which are long, get as much of it as the window allows.
function UI:layoutHeaderRow(y, width)
    local PAD = ListPanel.PAD
    local H = ListPanel.FONT_HGT_SMALL + 6
    -- ISLabel measures itself in its constructor, so this is the text width
    -- already, at whatever font scale the player is running.
    local vehW = self._vehicleLabel:getWidth() + 6
    local roomW = self._roomLabel:getWidth() + 6
    local spare = width - PAD * 2 - vehW - roomW - PAD * 2
    local each = math.max(math.floor(120 * ListPanel.FONT_SCALE), math.floor(spare / 2))

    local x = PAD
    self._vehicleLabel:setX(x)
    self._vehicleLabel:setY(y + 2)
    x = x + vehW
    self._vehicleCombo:setX(x)
    self._vehicleCombo:setY(y)
    self._vehicleCombo:setWidth(each)
    x = x + each + PAD

    self._roomLabel:setX(x)
    self._roomLabel:setY(y + 2)
    x = x + roomW
    self._roomCombo:setX(x)
    self._roomCombo:setY(y)
    self._roomCombo:setWidth(math.max(each, width - PAD - x))

    return H + PAD
end

--- Refill both dropdowns from the last payload, keeping the selection where
--- the selection still exists.
---
--- Rebuilt wholesale rather than patched, because a refresh can add or remove
--- a room -- the editor can create one -- and reconciling two lists against
--- each other is more code than refilling the shorter one. Eighty entries is
--- nothing; this runs on a refresh, not per frame.
function UI:rebuildPickers()
    local rooms = State.registry and State.registry.rooms or {}

    -- The vehicle list never depends on the room selection, so it only has to
    -- be refilled when the registry itself changes.
    local wanted = self._holder
    self._vehicleCombo:clear()
    self._vehicleCombo:addOptionWithData(getText(ANY), false)
    local found = false
    for _, name in ipairs(allHolders(rooms)) do
        self._vehicleCombo:addOptionWithData(name, name)
        if name == wanted then
            found = true
        end
    end
    -- A vehicle that has gone -- its mod uninstalled, its binding deleted --
    -- silently becomes "(any)" rather than leaving the box naming something
    -- that filters the room list down to nothing.
    self._holder = found and wanted or nil
    -- selectData rather than select: select matches on the visible TEXT, and
    -- the "(any)" entry is a translated string, so matching on it would break
    -- the moment somebody translated it.
    self._vehicleCombo:selectData(self._holder or false)

    self._roomCombo:clear()
    local stillThere = false

    -- Narrowed to one vehicle, the question is "which room does it GET", and
    -- that has an order: `rank` is the allocation order, so the room it would
    -- actually be given is first and the room it only overflows into is last.
    -- Alphabetically that comes out backwards as often as not -- Van_2x3 is
    -- the shed nearly everything overflows into and its id sorts before nearly
    -- every room that names it, so picking a van offered the fallback first.
    --
    -- With no vehicle chosen the question is "find room X" instead, and eighty
    -- ids are only scannable in alphabetical order, which is the order the
    -- payload already arrives in. So the sort is applied to the narrowed list
    -- and not to the whole one.
    local offered = {}
    for _, room in ipairs(rooms) do
        if roomReaches(room, self._holder) then
            table.insert(offered, room)
        end
    end
    if self._holder then
        table.sort(offered, function(a, b)
            -- A room from a server too old to send a rank sorts last rather
            -- than first, so a missing field cannot quietly become the answer.
            local ra = a.rank or math.huge
            local rb = b.rank or math.huge
            if ra ~= rb then
                return ra < rb
            end
            return a.id < b.id
        end)
    end
    for _, room in ipairs(offered) do
        self._roomCombo:addOptionWithData(room.id, room.id)
        if room.id == self.roomId then
            stillThere = true
        end
    end

    -- Only ever sets roomId. Fetching is the caller's job, so that this can be
    -- called from inside a refresh without starting a second one -- the detail
    -- request comes back through the same event that triggers a refresh, and
    -- the two chasing each other would not settle.
    -- `selected` is set on every path, and that is not belt and braces:
    -- ISComboBox:clear() empties the options and deliberately does NOT reset
    -- it, so narrowing 81 rooms down to one leaves it pointing at row 40 of a
    -- list with one row in it. addOptionWithData only rescues that when it was
    -- 0 to begin with.
    if stillThere then
        self._roomCombo:selectData(self.roomId)
    elseif self._roomCombo:getOptionCount() > 0 then
        -- The room on screen is not in the narrowed list. Follow the picker
        -- rather than leaving one room's slots under another room's name.
        self._roomCombo.selected = 1
        self.roomId = self._roomCombo:getOptionData(1)
    else
        self._roomCombo.selected = 0
        self.roomId = nil
    end
end

--- Rebuild the pickers, then draw whatever room they settled on.
---
--- This is what the shell's tab switch and the registry event both call. It
--- has to re-fetch as well as redraw, because a fresh room list clears every
--- cached slot payload -- State.receive does that deliberately, since slot
--- states are exactly what a refresh is likely to have changed.
function UI:refresh()
    self:rebuildPickers()
    if self.roomId then
        self:showRoom(self.roomId)
    else
        self:refreshList()
    end
end

--- ISComboBox calls onChange as (target, combo), so `self` is the panel.
function UI:onPickVehicle(combo)
    -- false is the data on the "(any)" entry, and it has to become nil:
    -- roomReaches reads nil as "no holder chosen" and false would be a holder
    -- named false, which nothing reaches.
    self._holder = combo:getOptionData(combo.selected) or nil
    self:refresh()
end

function UI:onPickRoom(combo)
    local picked = combo:getOptionData(combo.selected)
    if picked then
        self:showRoom(picked)
    end
end

function UI:getFilterText(itemData)
    return table.concat({tostring(itemData.index), itemData.position or "",
        itemData.state or "", itemData.lastUser or ""}, " ")
end

--- Point this tab at a room and ask the server for its slots.
---
--- The one way in, whoever is asking: the room picker, the Rooms tab's Slots
--- button, and the refresh all end here. The picker is re-selected rather than
--- assumed to be right, because two of those three callers are not the picker
--- and a dropdown naming one room over another room's slots is worse than no
--- dropdown.
function UI:showRoom(roomId)
    self.roomId = roomId
    if self._roomCombo and roomId then
        self._roomCombo:selectData(roomId)
    end
    if roomId and not State.detail[roomId] then
        Core.dispatch(Core.commands.roomSlots, {room = roomId})
    end
    self:refreshList()
end

function UI:refreshList()
    self:clearList()
    local detail = self.roomId and State.detail[self.roomId] or nil
    if not detail then
        -- Nothing drawn while the fetch is in flight. The tab title says which
        -- room, so an empty list here reads as "loading" rather than as "this
        -- room has no slots" -- which would be a real and alarming answer.
        return
    end

    for _, slot in ipairs(detail.slots or {}) do
        self:addListItem(tostring(slot.index), {
            key = tostring(slot.index),
            index = slot.index,
            position = slot.x and string.format("%d, %d, %d", slot.x, slot.y, slot.z) or
                getText("IGUI_PhunInteriors_Rooms_NoPosition"),
            state = stateText(slot),
            stateColour = slot.claimedBy and STATE_COLOURS.claimed or STATE_COLOURS[slot.state],
            lastIn = idleText(slot),
            -- Sorted and coloured on the number, drawn as the text.
            idleDays = slot.idleDays,
            lastUser = slot.lastUser or "",
            captured = slot.captured and getText("IGUI_PhunInteriors_Rooms_Captured") or "-",
            edited = slot.edited and getText("IGUI_PhunInteriors_Slot_Edited") or "",
            slot = slot
        })
    end
    self:applySort()
    self:applyFilter()
end

function UI:selectedSlot()
    local row = self:selectedRow()
    return row and row.slot or nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function UI:onEnterClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end
    Core.admin("enter", {room = self.roomId, index = slot.index})
end

--- Drop whoever holds this slot and mark it to be wiped when it is next
--- handed out. "Reset" on the button; `release` on the wire, because that is
--- what it does to the lease.
function UI:onReleaseClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end
    if slot.state == "free" then
        return
    end

    -- Refused here as well as on the server, so the answer is instant and the
    -- claim's owner is named. A claim makes a room permanent for as long as it
    -- stands, and resetting one would drop the lease and quarantine the slot,
    -- so its owner loses the room they claimed and its contents are scrubbed
    -- when it is next handed out.
    if slot.claimedBy then
        Core.client.notify({
            text = "IGUI_PhunInteriors_Slot_Claimed",
            warning = true
        })
        return
    end

    local tools = require "PhunInteriors/ui/ui_utils"
    -- Confirmed, unlike Enter: this one throws away a tenant's belongings the
    -- next time the slot is used, and the list gives no way to undo it.
    tools.confirm(getText("IGUI_PhunInteriors_Confirm_Reset", slot.index, self.roomId),
        function()
            Core.admin("release", {room = self.roomId, index = slot.index})
        end, self)
end

--- Take the room as it stands now as this slot's blueprint.
---
--- Needs the chunk loaded, which in practice means standing in it; the server
--- says so in plain words if not. Confirmed because it replaces what every
--- later scrub restores, and the old capture is not kept.
function UI:onRecaptureClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end
    local tools = require "PhunInteriors/ui/ui_utils"
    tools.confirm(getText("IGUI_PhunInteriors_Confirm_Recapture", slot.index, self.roomId),
        function()
            Core.admin("remanifest", {room = self.roomId, index = slot.index})
        end, self)
end

--- Put the slot back to its blueprint now, whoever holds it.
---
--- Unlike Reset it keeps the lease, which is what a hub wants: the same room,
--- cleaned. It does not ask who is standing in it, so what they have dropped
--- goes too; the confirm says so.
function UI:onScrubClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end
    local tools = require "PhunInteriors/ui/ui_utils"
    tools.confirm(getText("IGUI_PhunInteriors_Confirm_Scrub", slot.index, self.roomId),
        function()
            Core.admin("scrub", {room = self.roomId, index = slot.index})
        end, self)
end

--- Change where a stamp is, keeping its index.
---
--- The index is deliberately not editable here. Moving a slot's POSITION
--- leaves its lease pointing at the same stamp in a new place, which is
--- recoverable; changing its NUMBER re-points the lease at a different stamp,
--- which is not. Add and delete are how a numbering changes, and both are
--- explicit.
function UI:onMoveClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end
    require("PhunInteriors/ui/slot_form").open(self.player, self.roomId, slot)
end

function UI:onAddClick()
    if not self.roomId then
        return
    end
    -- Next free index, never a reused one. A number a lease may still name has
    -- to stay a gap: handing it to a new stamp points an old lease at it.
    local detail = State.detail[self.roomId]
    local next_ = 0
    for _, slot in ipairs(detail and detail.slots or {}) do
        if slot.index >= next_ then
            next_ = slot.index + 1
        end
    end
    require("PhunInteriors/ui/slot_form").open(self.player, self.roomId, {index = next_}, true)
end

function UI:onDeleteClick()
    local slot = self:selectedSlot()
    if not slot or not self.roomId then
        return
    end

    local tools = require "PhunInteriors/ui/ui_utils"
    -- A leased slot is refused rather than confirmed. Deleting one leaves a
    -- lease naming a stamp that no longer exists: Core.slotOrigin returns nil,
    -- and the next entry reads that as a stale lease and quietly releases it,
    -- taking the tenant's belongings with it.
    if slot.state ~= "free" then
        Core.client.notify({
            text = "IGUI_PhunInteriors_Slot_InUse",
            warning = true
        })
        return
    end

    tools.confirm(getText("IGUI_PhunInteriors_Confirm_DeleteSlot", slot.index, self.roomId),
        function()
            Core.dispatch(Core.commands.editRoom, {
                room = self.roomId,
                -- A LIST of indices rather than the `locations = {["3"] =
                -- false}` tombstone the file uses. The two say the same thing
                -- and the server turns this into that immediately, so there is
                -- still one internal representation -- but a table value of
                -- `false` has to survive PZ's command serialisation to reach
                -- the server, and a tombstone that quietly arrived as nil
                -- would read as "this patch mentions no such slot" and delete
                -- nothing, silently. A list of numbers cannot fail that way.
                removeSlots = {slot.index}
            })
        end, self)
end

-- No `UI.refresh = UI.refreshList` here any more. There was, and adding a
-- refresh of its own further up silently did nothing until this line went:
-- the assignment runs at file load and replaces the method however it was
-- defined. The symptom would have been pickers that never repopulated.

return UI
