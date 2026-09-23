if isServer() then
    return
end
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local FormPanel = require "PhunInteriors/ui/form_panel"
local State = Core.ui.state

local RoomForm = {}
Core.ui.room_form = RoomForm

-- ---------------------------------------------------------------------------
-- The room contract, as a form.
--
-- Everything here is a field registerRoom reads. What is deliberately NOT here
-- is anything about what is ON the squares: wallpaper, fittings, the light
-- switch and the roof are captured in game, per slot, on first lease, so a map
-- author can decorate the stamps differently and each is restored to what they
-- actually built. Opinionated about the shape, indifferent to the decor -- and
-- a form offering to edit the decor would be offering something that the next
-- capture overwrites.
--
-- Locations are not here either. They are the Slots tab, because the index is
-- the identity a lease persists and editing a list of a dozen of them in a
-- form field is how somebody renumbers the lot by accident.
--
-- Applying sends the WHOLE contract rather than a diff. The server diffs it
-- against the shipped definition and stores only what actually differs, which
-- is the one place that decision should live -- a client computing its own
-- diff would have to hold a second copy of every default to compare against,
-- and the two copies would disagree about, say, whether `reservoir` defaults
-- on the first time somebody changed it.
-- ---------------------------------------------------------------------------

-- Deliberately the same four the registry accepts, plus a "none" that is not
-- an edge. A room with no front lands its tenant beside the holder, which is a
-- real answer that four of the shipped rooms choose on purpose -- so it is the
-- first option rather than a blank.
local EDGES = {"none", "north", "south", "east", "west"}

-- The three answers for hardenShell, in the order the combo shows them. The
-- first is nil on the wire, which is what makes "follow the server" a real
-- third state rather than a false that happens to match today's setting.
local HARDEN = {"server", "always", "never"}

local function hardenIndex(value)
    if value == true then
        return 2
    elseif value == false then
        return 3
    end
    return 1
end

local function edgeIndex(front)
    for i, edge in ipairs(EDGES) do
        if edge == front then
            return i
        end
    end
    return 1
end

--- Mark a label when this field is one the admin has already changed.
---
--- The payload's `patched` set is the server's own answer -- the keys actually
--- stored in the override -- rather than the form comparing what it was given
--- against a second copy of every default. That copy is the thing to avoid: it
--- would have to agree with registerRoom about, say, whether `reservoir`
--- defaults on, and the first time the two disagreed a stock field would read
--- as customised with nothing to revert.
---
--- A marker rather than per-field revert, because Revert is whole-room. This
--- says which fields it would undo.
local function label(room, key, text)
    if room and room.patched and room.patched[key] then
        return text .. " *"
    end
    return text
end

--- A number out of a text field, or nil when it is blank or not one.
local function num(form, key)
    local text = form:getFieldValue(key)
    if text == nil or text == "" then
        return nil
    end
    return tonumber(text)
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

--- Edit `roomId`, or create a room when it is nil.
function RoomForm.open(player, roomId)
    local room = roomId and State.room(roomId) or nil
    local creating = room == nil

    if roomId and not room then
        return nil
    end

    -- A new room needs somewhere to be, and the only position the client can
    -- name without inventing one is where the admin is standing. Same
    -- principle the authoring tool works on: read the coordinates off your
    -- feet rather than asking somebody to type them.
    local here = player and {
        x = math.floor(player:getX()),
        y = math.floor(player:getY()),
        z = math.floor(player:getZ())
    } or {x = 0, y = 0, z = 0}

    local form
    form = FormPanel:new({
        title = creating and getText("IGUI_PhunInteriors_Form_NewRoom") or
            getText("IGUI_PhunInteriors_Form_EditRoom", roomId),
        width = math.floor(460 * FormPanel.FONT_SCALE),
        onApply = function(f)
            RoomForm.apply(roomId, creating, f)
        end
    })

    ---------------------------------------------------------------------
    -- Shape
    ---------------------------------------------------------------------
    if creating then
        form:addTextField("id", getText("IGUI_PhunInteriors_Fld_Id"), {
            hint = getText("IGUI_PhunInteriors_Hint_RoomId"),
            required = true,
            section = "shape"
        })
    end
    form:addTextField("label", label(room, "label", getText("IGUI_PhunInteriors_Fld_Label")), {
        default = room and room.label or "",
        section = "shape"
    })

    -- Footprint, and the hint says so. `size` is the box the registration
    -- declares, and this map draws the south and east walls OUTSIDE the floor
    -- -- so the floor is the box less its last row and column, and a 3x4
    -- footprint is a 2x3 floor. Registering the ambulance bays as the 2x3 they
    -- replaced left a box that excluded both their walls, and every other
    -- check passed.
    form:addTextField("sizeW", label(room, "size", getText("IGUI_PhunInteriors_Fld_SizeW")), {
        default = tostring(room and room.size and room.size.w or 3),
        numeric = true,
        integer = true,
        min = 1,
        required = true,
        hint = getText("IGUI_PhunInteriors_Hint_Size"),
        section = "shape"
    })
    form:addTextField("sizeH", label(room, "size", getText("IGUI_PhunInteriors_Fld_SizeH")), {
        default = tostring(room and room.size and room.size.h or 4),
        numeric = true,
        integer = true,
        min = 1,
        required = true,
        section = "shape"
    })

    -- Spawn is an OFFSET into the room, not a world position, and the hint
    -- says that too -- the two are easy to confuse in a window that shows
    -- world coordinates on the Slots tab. It also has to be a square a tenant
    -- can stand on: a solid or solidtrans tile there drops them inside a
    -- locker, which is why furnishing a room is a registry change and not just
    -- decor.
    form:addTextField("spawnX", label(room, "spawn", getText("IGUI_PhunInteriors_Fld_SpawnX")), {
        default = tostring(room and room.spawn and room.spawn.x or 1),
        numeric = true,
        integer = true,
        min = 0,
        hint = getText("IGUI_PhunInteriors_Hint_Spawn"),
        section = "shape"
    })
    form:addTextField("spawnY", label(room, "spawn", getText("IGUI_PhunInteriors_Fld_SpawnY")), {
        default = tostring(room and room.spawn and room.spawn.y or 1),
        numeric = true,
        integer = true,
        min = 0,
        section = "shape"
    })

    if creating then
        form:addSeparator("sep_where", {
            text = getText("IGUI_PhunInteriors_Sec_FirstStamp"),
            section = "shape"
        })
        form:addTextField("locX", getText("IGUI_PhunInteriors_Fld_WorldX"), {
            default = tostring(here.x),
            numeric = true,
            integer = true,
            required = true,
            hint = getText("IGUI_PhunInteriors_Hint_FirstStamp"),
            section = "shape"
        })
        form:addTextField("locY", getText("IGUI_PhunInteriors_Fld_WorldY"), {
            default = tostring(here.y),
            numeric = true,
            integer = true,
            required = true,
            section = "shape"
        })
        form:addTextField("locZ", getText("IGUI_PhunInteriors_Fld_WorldZ"), {
            default = tostring(here.z),
            numeric = true,
            integer = true,
            section = "shape"
        })
    end

    ---------------------------------------------------------------------
    -- The way out
    ---------------------------------------------------------------------
    form:addComboField("front", label(room, "front", getText("IGUI_PhunInteriors_Fld_Front")), {
        options = EDGES,
        selected = edgeIndex(room and room.front),
        hint = getText("IGUI_PhunInteriors_Hint_Front"),
        section = "exit"
    })
    form:addCheckField("cab", label(room, "cab", getText("IGUI_PhunInteriors_Fld_Cab")), {
        checked = room and room.cab or false,
        hint = getText("IGUI_PhunInteriors_Hint_Cab"),
        section = "exit"
    })

    ---------------------------------------------------------------------
    -- Power
    ---------------------------------------------------------------------
    -- A tick plus three offsets rather than three offsets that mean "none"
    -- when blank. Nil means NO GENERATOR and there is deliberately no default
    -- position, because a wrong one fails silently and self-heals into looking
    -- deliberate -- `power` used to default to {0,0,1} and built a generator
    -- on the roof of every room while fifty good ones sat 17 tiles south.
    -- Making the absence an explicit tick is the form saying the same thing.
    local hasGenerator = room and room.generator ~= nil or false
    form:addCheckField("hasGenerator", label(room, "generator", getText("IGUI_PhunInteriors_Fld_HasGenerator")), {
        checked = hasGenerator,
        hint = getText("IGUI_PhunInteriors_Hint_HasGenerator"),
        section = "power",
        onChange = function()
            form:setFieldVisible("genX", form:getFieldValue("hasGenerator"))
            form:setFieldVisible("genY", form:getFieldValue("hasGenerator"))
            form:setFieldVisible("genZ", form:getFieldValue("hasGenerator"))
        end
    })
    form:addTextField("genX", getText("IGUI_PhunInteriors_Fld_GenX"), {
        default = tostring(room and room.generator and room.generator.x or 0),
        numeric = true,
        integer = true,
        hint = getText("IGUI_PhunInteriors_Hint_Generator"),
        section = "power",
        conditional = true
    })
    form:addTextField("genY", getText("IGUI_PhunInteriors_Fld_GenY"), {
        default = tostring(room and room.generator and room.generator.y or 17),
        numeric = true,
        integer = true,
        section = "power",
        conditional = true
    })
    form:addTextField("genZ", getText("IGUI_PhunInteriors_Fld_GenZ"), {
        default = tostring(room and room.generator and room.generator.z or 0),
        numeric = true,
        integer = true,
        section = "power",
        conditional = true
    })
    form:addCheckField("selfPowered", label(room, "selfPowered", getText("IGUI_PhunInteriors_Fld_SelfPowered")), {
        checked = room and room.selfPowered or false,
        hint = getText("IGUI_PhunInteriors_Hint_SelfPowered"),
        section = "power"
    })

    ---------------------------------------------------------------------
    -- Everything else
    ---------------------------------------------------------------------
    -- There are no "needs cargo space" / "needs a charged battery" ticks here.
    -- A room could once demand those of the vehicle leasing it (`requires`),
    -- and the whole field is gone -- nothing on the shipped map declared one,
    -- and it was a vehicle question asked during allocation, which is holder
    -- agnostic. Which holders reach a room is the Bindings tab's answer.
    form:addCheckField("reservoir", label(room, "reservoir", getText("IGUI_PhunInteriors_Fld_Reservoir")), {
        checked = room == nil or room.reservoir ~= false,
        hint = getText("IGUI_PhunInteriors_Hint_Reservoir"),
        section = "other"
    })
    form:addCheckField("singleUse", label(room, "singleUse", getText("IGUI_PhunInteriors_Fld_SingleUse")), {
        checked = room and room.singleUse or false,
        hint = getText("IGUI_PhunInteriors_Hint_SingleUse"),
        section = "other"
    })
    form:addCheckField("shared", label(room, "shared", getText("IGUI_PhunInteriors_Fld_Shared")), {
        checked = room and room.shared or false,
        hint = getText("IGUI_PhunInteriors_Hint_Shared"),
        section = "other"
    })
    form:addComboField("hardenShell", label(room, "hardenShell", getText("IGUI_PhunInteriors_Fld_HardenShell")), {
        options = HARDEN,
        selected = hardenIndex(room and room.hardenShell),
        hint = getText("IGUI_PhunInteriors_Hint_HardenShell"),
        section = "other"
    })
    form:addTextField("priority", label(room, "priority", getText("IGUI_PhunInteriors_Fld_Priority")), {
        default = tostring(room and room.priority or 0),
        numeric = true,
        integer = true,
        hint = getText("IGUI_PhunInteriors_Hint_Priority"),
        section = "other"
    })
    form:addTextField("baseWeight", label(room, "baseWeight", getText("IGUI_PhunInteriors_Fld_BaseWeight")), {
        default = tostring(room and room.baseWeight or 0),
        numeric = true,
        min = 0,
        hint = getText("IGUI_PhunInteriors_Hint_BaseWeight"),
        section = "other"
    })

    -- `section`, not `key`. _applySection matches on f.section == s.section,
    -- and a descriptor keyed the other way silently matches nothing -- every
    -- field ends up hidden with a row of tabs that do nothing.
    form:setSections({
        {section = "shape", label = getText("IGUI_PhunInteriors_Sec_Shape")},
        {section = "exit", label = getText("IGUI_PhunInteriors_Sec_Exit")},
        {section = "power", label = getText("IGUI_PhunInteriors_Sec_Power")},
        {section = "other", label = getText("IGUI_PhunInteriors_Sec_Other")}
    })

    form:initialise()
    -- After initialise, which is where the widgets come from: the three
    -- generator offsets are conditional on the tick above them, and a form
    -- opened for a room with no generator should not show them.
    form:setFieldVisible("genX", hasGenerator)
    form:setFieldVisible("genY", hasGenerator)
    form:setFieldVisible("genZ", hasGenerator)
    form:addToUIManager()
    form:bringToTop()
    return form
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

--- Turn the form into an editRoom command.
---
--- Takes the FORM and reads every field off it. FormPanel calls onApply as
--- `self._onApply(self)` -- the form, not a values table -- and this used to
--- be written as though it received the values. Every field read that way came
--- back nil, so `label`, `front`, `cab`, `selfPowered` and `reservoir` were
--- silently dropped from the patch while the numeric fields, which went
--- through form:getFieldValue all along, went through fine. It presented as
--- "changing the label does not persist", which is the one of those five a
--- person is most likely to try first.
function RoomForm.apply(roomId, creating, form)
    local label = form:getFieldValue("label") or ""
    local id = roomId or (form:getFieldValue("id") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not id or id == "" then
        return
    end

    local args = {
        room = id,
        label = label ~= "" and label or nil,
        size = {w = num(form, "sizeW"), h = num(form, "sizeH")},
        spawn = {x = num(form, "spawnX") or 0, y = num(form, "spawnY") or 0},
        cab = form:getFieldValue("cab") and true or false,
        selfPowered = form:getFieldValue("selfPowered") and true or false,
        singleUse = form:getFieldValue("singleUse") and true or false,
        shared = form:getFieldValue("shared") and true or false,
        reservoir = form:getFieldValue("reservoir") and true or false,
        priority = num(form, "priority") or 0,
        baseWeight = num(form, "baseWeight") or 0,
        -- Names the fields that go back to nothing, because JSON null cannot
        -- say it and neither can an absent key: a patch that simply omits
        -- `front` means "no opinion", not "no front". Without this an admin
        -- could give a room a generator and never take it away again.
        clear = {}
    }

    local front = form:getFieldValue("front")
    if front == "none" or front == nil or front == "" then
        table.insert(args.clear, "front")
    else
        args.front = front
    end

    -- "server" is a clear rather than a false, for the reason `front`'s
    -- "none" is: omitting the field would mean "no opinion" and leave an
    -- earlier always or never in place.
    local harden = form:getFieldValue("hardenShell")
    if harden == "always" then
        args.hardenShell = true
    elseif harden == "never" then
        args.hardenShell = false
    else
        table.insert(args.clear, "hardenShell")
    end

    if form:getFieldValue("hasGenerator") then
        args.generator = {
            x = num(form, "genX") or 0,
            y = num(form, "genY") or 0,
            z = num(form, "genZ") or 0
        }
    else
        table.insert(args.clear, "generator")
    end

    if creating then
        -- A new room needs at least one stamp or registerRoom refuses it --
        -- "ended up with no locations" -- and the refusal would arrive as a
        -- room that simply did not appear. Index 0, and every later stamp is
        -- added from the Slots tab.
        args.locations = {
            ["0"] = {num(form, "locX") or 0, num(form, "locY") or 0, num(form, "locZ") or 0}
        }
    end

    Core.dispatch(Core.commands.editRoom, args)
    -- Closed here rather than left open. A room form is a thing you fill in
    -- and are done with, unlike the room list behind it, which stays up
    -- precisely because walking a set of stamps means using it repeatedly.
    form:close()
end

return RoomForm
