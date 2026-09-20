if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Scrub = require "PhunInteriors/scrub"
local Manifest = require "PhunInteriors/manifest"
local Transit = require "PhunInteriors/transit"
local Admin = {}
Core.modules.admin = Admin

-- ---------------------------------------------------------------------------
-- Admin actions.
--
-- PhunServer2 is a hook, never a dependency. When it is loaded these register
-- as chat commands; when it is not, they are still reachable through the
-- client command path. This mod has no hard dependencies.
-- ---------------------------------------------------------------------------

local actions = {}

actions.list = function()
    local summary = Slots.summary()
    local lines = {}

    for _, room in ipairs(summary.rooms) do
        table.insert(lines, string.format("%s: %d/%d leased (%s)",
            room.id, room.used, room.total, room.source))
    end

    -- Longest idle first, because that is the next one a full pool would take
    -- and the one you want the id of.
    for _, lease in ipairs(summary.leases) do
        table.insert(lines, string.format("  %s -> %s#%s, idle %.1f day(s)%s%s%s%s",
            lease.vehicleId, lease.room, lease.index, lease.idleDays,
            lease.lastUser and (", last used by " .. lease.lastUser) or "",
            lease.occupied and ", occupied now" or "",
            lease.claimedBy and (", safehouse of " .. lease.claimedBy) or "",
            lease.reclaimable and ", reclaimable" or ""))
        -- Where an exit would put them, and whether that is a live reading or
        -- the frozen one. Nothing else surfaces this, and every exit depends
        -- on it being right.
        table.insert(lines, string.format("      vehicle at %s (%s)",
            lease.at and string.format("%d,%d,%d", lease.at.x, lease.at.y, lease.at.z)
                or "nowhere recorded",
            lease.loaded and "loaded" or "unloaded, frozen"))
    end

    table.insert(lines, string.format("quarantine: %d slot(s) awaiting scrub%s",
        summary.quarantine, summary.quarantined or ""))
    return lines
end

-- Take the room a full pool would take next, without filling the pool.
--
-- A reclaim only happens by itself when every room a vehicle could have is
-- leased -- 1200 of them on the shipped map -- so without this it is never
-- seen. It chooses with the same function allocation does, then releases, and
-- the slot is scrubbed when it is next handed out. Pair with age.
actions.reclaim = function(args)
    local rooms = nil
    if args.room then
        if not Core.rooms[args.room] then
            return {"there is no room called " .. tostring(args.room)}
        end
        rooms = {[args.room] = 1}
    end
    local holder, taken = Slots.oldestReclaimable(rooms)
    if not holder then
        return {string.format("nothing reclaimable%s: every lease is occupied or used within %s day(s)",
            args.room and (" in " .. args.room) or "", tostring(Core.settings.RoomProtectedDays)),
            "  note: entering a room renews its lease, so age it and reclaim with nothing in between"}
    end
    Slots.release(holder, "reclaimed by an admin")
    return {string.format("reclaimed %s#%s from %s; it is scrubbed when it is next handed out",
        taken.room, tostring(taken.index), tostring(holder))}
end

-- Pretend a lease has not been touched for this many days, so it is past its
-- protection. Pair with reclaim to test without waiting or filling the pool.
actions.age = function(args)
    local vehicleId = args.vehicleId
    local days = tonumber(args.days) or 999
    if not vehicleId then
        return {"age needs a vehicleId, and optionally days"}
    end
    local assignment = Slots.age(vehicleId, days)
    if not assignment then
        return {"no room is leased to " .. tostring(vehicleId)}
    end
    return {string.format("%s#%s now looks %s days idle",
        assignment.room, assignment.index, tostring(days))}
end

-- Re-read the sandbox options now.
--
-- Settings are cached and refreshed on EveryTenMinutes, so changing one mid
-- session appears to do nothing for up to ten minutes. That is fine in play
-- and awful while testing: a WeightFactor change looks like a broken
-- recalculation rather than a stale cache.
actions.reload = function()
    Core.refreshSettings()
    local shown = {}
    for name in pairs(Core.defaults) do
        table.insert(shown, name)
    end
    table.sort(shown)
    local lines = {"settings re-read from sandbox options:"}
    for _, name in ipairs(shown) do
        table.insert(lines, string.format("  %s = %s", name, tostring(Core.settings[name])))
    end
    return lines
end

-- What each leased vehicle is being charged for its interior.
actions.weight = function()
    return require("PhunInteriors/weight").report()
end

actions.free = function(args)
    local vehicleId = args.vehicleId
    if not vehicleId then
        return {"free needs a vehicleId"}
    end
    if Slots.release(vehicleId, "admin") then
        return {"released the room leased to " .. tostring(vehicleId)}
    end
    return {"no room is leased to " .. tostring(vehicleId)}
end

-- ---------------------------------------------------------------------------
-- Power probe.
--
-- Groundwork for binding the interior generator to the vehicle battery, and
-- the tool that settled how B42 electricity actually works. The jar answered
-- it in the end; this reports the state so a room can be checked in game.
--
-- Three facts, all read out of the bytecode (Docs/body.pl):
--
--   haveElectricity() ignores every field. It is
--     chunk:isGeneratorPoweringSquare(x, y, z), with an early false for an
--     exterior square when AllowExteriorGenerator is off. Generator power is
--     therefore only ever real generator power.
--
--   setHaveElectricity(boolean) does not set anything. It ignores its argument
--     and calls update() on any IsoLightSwitch on the square. It is a refresh
--     with a setter's name.
--
--   hasGridPower() is (not isNoPower()) and doesPowerGridExist(), and
--     isNoPower() is isDerelict() or isUserDefinedRoom() or the square sitting
--     in a map zone of type "NoPower" or "NoPowerOrWater".
--
-- So the mains cannot be switched off from Lua, but it can be switched off on
-- the map: a NoPower zone painted over the interior block makes hasGridPower
-- false there for good, leaving the generator as the only source. That is a
-- job for whoever builds the map, and this reports whether they have done it.
--
--     PhunInteriors.admin("power")
--     PhunInteriors.admin("power", {room = "phun.van", index = 3})
--
-- With no slot it reports every slot somebody is standing in, because that is
-- the only one guaranteed to be loaded.
-- ---------------------------------------------------------------------------

--- The slots worth reporting on: the one asked for, else whatever is occupied.
local function slotsToProbe(args)
    local out = {}
    if args.room and args.index then
        table.insert(out, {room = args.room, index = tonumber(args.index)})
        return out
    end
    for _, occupancy in pairs(Core.occupants) do
        table.insert(out, {room = occupancy.room, index = occupancy.index})
    end
    return out
end

--- The generator on a square, if there is one.
local function generatorOn(square)
    local objects = square and square:getObjects()
    if not objects then
        return nil
    end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and instanceof(object, "IsoGenerator") then
            return object
        end
    end
    return nil
end

actions.power = function(args)
    local lines = {}

    -- The engine's own test, the one hasGridPower calls, rather than a
    -- reimplementation of the shutoff arithmetic.
    table.insert(lines, string.format("power grid exists: %s (ElecShutModifier %s)",
        tostring(getSandboxOptions():doesPowerGridExist()),
        tostring(getSandboxOptions():getElecShutModifier())))

    local targets = slotsToProbe(args)
    if #targets == 0 then
        table.insert(lines, "no slot given and nobody is inside one; " ..
            "pass room and index, or stand in a room")
        return lines
    end

    for _, target in ipairs(targets) do
        local room = Core.rooms[target.room]
        if not room then
            table.insert(lines, "unknown room " .. tostring(target.room))
        else
            local bounds = Core.slotBounds(room, target.index)
            -- nil when the room declares no generator, which means a room meant
            -- to have no power rather than one whose position we failed to find
            local power = Core.slotPower(room, target.index)
            if not bounds then
                return {string.format("%s has no slot %s", tostring(target.room), tostring(target.index))}
            end
            if power then
                table.insert(lines, string.format("%s#%s, power square %d,%d,%d",
                    target.room, target.index, power.x, power.y, power.z))
            else
                table.insert(lines, string.format("%s#%s, no generator by design",
                    target.room, target.index))
            end

            local counted, elec, grid, noPower, derelict, userRoom = 0, 0, 0, 0, 0, 0
            local zones = {}
            for z = bounds.z, bounds.z + 1 do
                for x = bounds.x1, bounds.x2 do
                    for y = bounds.y1, bounds.y2 do
                        local square = getCell():getGridSquare(x, y, z)
                        if square then
                            counted = counted + 1
                            if square:haveElectricity() then elec = elec + 1 end
                            if square:hasGridPower() then grid = grid + 1 end
                            if square:isNoPower() then noPower = noPower + 1 end
                            if square:isDerelict() then derelict = derelict + 1 end
                            if square:isUserDefinedRoom() then userRoom = userRoom + 1 end
                            local zone = square:getZoneType()
                            if zone and zone ~= "" then
                                zones[zone] = (zones[zone] or 0) + 1
                            end
                        end
                    end
                end
            end

            if counted == 0 then
                table.insert(lines, "  chunk is not loaded, nothing to read")
            else
                table.insert(lines, string.format(
                    "  %d square(s): haveElectricity %d, hasGridPower %d, isNoPower %d",
                    counted, elec, grid, noPower))
                -- The three things isNoPower is made of, so a room that is
                -- still on the mains says why.
                table.insert(lines, string.format(
                    "  isDerelict %d, isUserDefinedRoom %d, zones: %s",
                    derelict, userRoom,
                    Core.tools.isEmpty(zones) and "none" or (function()
                        local names = {}
                        for name, n in pairs(zones) do
                            table.insert(names, name .. " x" .. n)
                        end
                        return table.concat(names, ", ")
                    end)()))

                if noPower == 0 and getSandboxOptions():doesPowerGridExist() then
                    table.insert(lines, "  NOTE: on the mains. Paint a NoPower zone "
                        .. "over this block on the map and the generator becomes "
                        .. "the only source.")
                end

                local generatorSquare = power and getCell():getGridSquare(power.x, power.y, power.z)
                local generator = generatorSquare and generatorOn(generatorSquare)
                if not power then
                    table.insert(lines, "  this room is unpowered by design; no generator expected")
                elseif not generatorSquare then
                    table.insert(lines, "  power square is not loaded")
                elseif generator then
                    table.insert(lines, string.format(
                        "  generator: activated %s, fuel %.1f/%.1f, condition %d, drawing %.2f",
                        tostring(generator:isActivated()), generator:getFuel(),
                        generator:getMaxFuel(), generator:getCondition(),
                        generator:getTotalPowerUsing()))
                else
                    table.insert(lines, "  no generator on the power square")
                end

                -- The ledger. Nothing else shows it, and it is the whole
                -- mechanism: the room and the vehicle are never loaded at the
                -- same time, so the debt between them lives here.
                local Power = require "PhunInteriors/power"
                for vehicleId, assignment in pairs(Slots.store().assignments) do
                    if assignment.room == target.room
                        and assignment.index == target.index then
                        table.insert(lines, string.format(
                            "  ledger: battery last read %.0f%%, %.1f fuel owed, "
                            .. "projected %.0f%%",
                            (tonumber(assignment.batteryKnown) or 0) * 100,
                            tonumber(assignment.fuelOwed) or 0,
                            Power.projectedCharge(assignment) * 100))
                    end
                end
            end
        end
    end

    return lines
end

-- ---------------------------------------------------------------------------
-- The room list, and porting into one.
--
-- A room designer's loop is: look at the rooms that exist, stand in one, see
-- whether the stamp came out right, reset it, look again. Doing that through
-- the front door means spawning a vehicle of the right script, parking it,
-- climbing in, and taking whatever the allocator hands out -- which for a room
-- low in the specificity order may be nothing at all.
--
-- roomState is the structured answer, and it is deliberately the only one:
-- both the window and the text list below render it, so there is no second
-- place for the truth about a room to live.
-- ---------------------------------------------------------------------------

--- Who holds what and what is dirty, flattened once rather than searched per
--- slot. Two of these walks against 960 slots is cheaper than 960 walks of the
--- lease table, and both callers below need the same three answers.
local function occupancyIndex()
    local d = Slots.store()
    local holder, quarantined, occupied, lease = {}, {}, {}, {}
    for vehicleId, assignment in pairs(d.assignments) do
        local key = assignment.room .. "#" .. tostring(assignment.index)
        holder[key] = vehicleId
        -- The assignment as well as the id, because the slot list wants what
        -- is ON the lease -- how long since anybody was in, and who. The id
        -- stays because it is what says whether the lease is this admin's.
        lease[key] = assignment
    end
    for _, entry in ipairs(d.quarantine) do
        quarantined[entry.room .. "#" .. tostring(entry.index)] = true
    end
    for _, occupancy in pairs(Core.occupants) do
        occupied[occupancy.room .. "#" .. tostring(occupancy.index)] = true
    end
    return holder, quarantined, occupied, lease
end

--- Which items reach `roomId`, for a room bound to world objects rather than
--- vehicles. Core.scriptsForRoom answers the vehicle half; nothing answered
--- this one, so a tent room showed "reachable by nothing" in the list.
local function itemsForRoom(roomId)
    local items, seen = {}, {}
    for _, binding in pairs(Core.bindings) do
        local names = binding.kind == "object" and binding.items or nil
        if names then
            for _, roomName in ipairs(binding.rooms) do
                if roomName == roomId then
                    for _, item in ipairs(names) do
                        if not seen[item] then
                            seen[item] = true
                            table.insert(items, item)
                        end
                    end
                end
            end
        end
    end
    table.sort(items)
    return items
end

--- The contract fields, as the editor reads and writes them.
---
--- Taken off a room table rather than off the definition, so what is shown is
--- what the mod is actually USING -- normalised, defaulted and with any patch
--- already on it. A form fed the raw definition would show `cab` as nil for
--- every room that never mentioned it, and applying that form back would write
--- an override saying false where the shipped value was already false.
local function contractOf(room)
    return {
        label = room.label,
        priority = room.priority,
        size = {w = room.size.w, h = room.size.h},
        spawn = {x = room.spawn.x, y = room.spawn.y},
        front = room.front,
        cab = room.cab and true or false,
        generator = room.generator and {
            x = room.generator.x,
            y = room.generator.y,
            z = room.generator.z or 0
        } or nil,
        selfPowered = room.selfPowered and true or false,
        reservoir = room.reservoir ~= false,
        baseWeight = room.baseWeight or 0
    }
end

--- Every room, without its slots. The list payload.
function Admin.roomState(player)
    local mine = player and Core.adminKey(player) or nil
    local out = {
        rooms = {},
        -- Which slot this admin is standing in, if any. The window greys its
        -- Enter button on it, and there is no other way for a client to know:
        -- occupancy is server side and is never sent down except as a bare
        -- "you are inside" flag.
        me = mine,
        -- So the window can say whether the file on disk is behind the
        -- registry. There is no autosave: an edit applies immediately and is
        -- written when somebody presses Save, because a mistake that is
        -- already on disk is a mistake an admin has to undo by hand.
        unsaved = Core.unsavedEdits == true
    }

    local holder, quarantined = occupancyIndex()

    for id, room in pairs(Core.rooms) do
        local scripts, matchers = Core.scriptsForRoom(id)
        local entry = contractOf(room)
        entry.id = id
        entry.source = room.source
        -- "powered" is whether there is a generator at all, and is deliberately
        -- a different word from `selfPowered`, which is whether its fuel is
        -- free. One word meaning both is how a reader ends up confidently
        -- wrong; see registerRoom.
        entry.powered = room.generator ~= nil
        entry.scripts = scripts
        entry.items = itemsForRoom(id)
        entry.matchers = matchers
        -- Where this room sits in the allocation order: which of them
        -- `Slots.acquire` would spend first. Sent rather than derived, because
        -- deriving it client side is a second copy of the specificity
        -- arithmetic and a second copy can disagree with the one that actually
        -- hands rooms out.
        entry.rank = (Core.roomRank or {})[id]
        entry.total = #room.indices
        entry.leased = 0
        entry.quarantined = 0
        -- shipped / overridden / new, which is what the list colours a row by
        -- and what decides whether Revert is offered at all.
        entry.state = Core.roomOverrideState(id)
        entry.patched = {}
        for field in pairs(Core.overrides.rooms[id] or {}) do
            entry.patched[field] = true
        end

        -- Counted here rather than sent per slot: the list shows totals, and
        -- the 960 slot records this used to carry were drawn by nothing until
        -- a row was selected.
        for _, index in ipairs(room.indices) do
            local key = id .. "#" .. tostring(index)
            if holder[key] then
                entry.leased = entry.leased + 1
            elseif quarantined[key] then
                entry.quarantined = entry.quarantined + 1
            end
        end

        table.insert(out.rooms, entry)
    end

    table.sort(out.rooms, function(a, b)
        return a.id < b.id
    end)
    return out
end

--- One room's slots.
---
--- Fetched when a row is selected, rather than sent with the list: 960 slot
--- records crossing sendServerCommand on every refresh is most of a payload
--- that nothing draws until a row is picked.
---
--- It deliberately does NOT carry the shipped contract for comparison. That
--- was built and removed the same afternoon: nothing read it, because per-field
--- revert is not a thing this editor does -- Revert is whole-room, and the
--- fields an admin changed are marked from `patched` in the list payload,
--- which is already there. A second copy of every room's contract riding down
--- so that nothing could use it is the sort of payload nobody notices until it
--- is the reason a dedicated server drops the message.
function Admin.roomDetail(player, roomId)
    local room = Core.rooms[roomId]
    if not room then
        return {room = roomId, missing = true, slots = {}}
    end

    local mine = player and Core.adminKey(player) or nil
    local holder, quarantined, occupied, leases = occupancyIndex()
    local out = {
        room = roomId,
        state = Core.roomOverrideState(roomId),
        slots = {}
    }

    local now = Core.now()
    for _, index in ipairs(room.indices) do
        local key = roomId .. "#" .. tostring(index)
        local origin = Core.slotOrigin(room, index)
        local heldBy = holder[key]
        local lease = leases[key]
        local state = "free"
        if heldBy then
            state = (heldBy == mine) and "mine" or "leased"
        elseif quarantined[key] then
            state = "quarantine"
        end
        table.insert(out.slots, {
            index = index,
            x = origin and origin.x,
            y = origin and origin.y,
            z = origin and origin.z,
            state = state,
            occupied = occupied[key] or nil,
            -- HOW LONG SINCE ANYBODY WAS IN, in world days, and WHO. This is
            -- what decides whether a slot is worth resetting, and it is the
            -- same pair of facts the reclaim picks on -- `lastSeen` is what
            -- Slots.isReclaimable measures against RoomProtectedDays. Showing
            -- the holder's id instead answered a question nobody was asking:
            -- a UUID cannot be recognised, and "how long has this been dead"
            -- can.
            idleDays = lease and ((now - (lease.lastSeen or now)) / 24) or nil,
            lastUser = lease and lease.lastUser or nil,
            -- A claim makes a room permanent for as long as it stands, so a
            -- reset has to refuse it -- and the list has to say why before
            -- somebody tries.
            claimedBy = (function()
                local claim = Slots.safehouseOn(roomId, index)
                return claim and tostring(claim:getOwner()) or nil
            end)(),
            -- Whether this stamp ever recorded its own decor. A room full of
            -- uncaptured slots means capture is failing, and that is invisible
            -- everywhere else until a scrub restores the wrong wallpaper.
            captured = Manifest.hasCapture(roomId, index) and true or false,
            -- Whether the admin has moved or added this one. A moved slot
            -- whose lease is still live is the single most dangerous edit in
            -- the window, so it is marked rather than merely allowed.
            edited = (Core.overrides.rooms[roomId] and Core.overrides.rooms[roomId].locations
                and Core.overrides.rooms[roomId].locations[index] ~= nil) or nil
        })
    end

    return out
end

--- Every binding, for the editor's other tab.
function Admin.bindingState()
    local out = {}
    for id, binding in pairs(Core.bindings) do
        table.insert(out, {
            id = id,
            kind = binding.kind,
            source = binding.source,
            scripts = binding.scripts or {},
            items = binding.items or {},
            rooms = binding.rooms or {},
            -- A predicate cannot be sent and cannot be edited -- it is a Lua
            -- function in somebody else's file. Saying it is there is the most
            -- the window can do, and saying nothing would present a binding
            -- that claims every StepVan in the game as one naming no scripts.
            matcher = binding.match ~= nil,
            state = Core.overrides.bindings[id] and "overridden" or "shipped"
        })
    end
    table.sort(out, function(a, b)
        return a.id < b.id
    end)
    return out
end

-- The same state as text, for the console and for PhunServer2 chat.
actions.rooms = function(args, player)
    local state = Admin.roomState(player)
    local lines = {}
    -- `filter` is the same substring test the window's filter box runs, so a
    -- room found one way is found the other. It reads id, label, script and
    -- item, because "which room does the mail van get" is asked as often as
    -- "show me the bar".
    local filter = args and args.filter and string.lower(tostring(args.filter)) or nil

    for _, room in ipairs(state.rooms) do
        if not filter or Admin.roomMatches(room, filter) then
            local reach = table.concat(room.scripts, ", ")
            if #room.items > 0 then
                reach = (reach == "" and "" or reach .. ", ") .. table.concat(room.items, ", ")
            end
            if room.matchers > 0 then
                reach = (reach == "" and "" or reach .. ", ") .. room.matchers .. " matcher(s)"
            end
            table.insert(lines, string.format("%s: %d slot(s), %d leased, %d quarantined, %s%s%s",
                room.id, room.total, room.leased, room.quarantined,
                room.powered and (room.selfPowered and "powered (free)" or "powered") or "no generator",
                reach == "" and ", reachable by nothing" or (" <- " .. reach),
                room.state == "shipped" and "" or (" [" .. room.state .. "]")))
        end
    end

    if #lines == 0 then
        table.insert(lines, filter and ("no room matches '" .. filter .. "'") or
            "no rooms are registered")
    elseif state.unsaved then
        table.insert(lines, "there are unsaved changes; PhunInteriors.admin(\"save\") writes them")
    end
    return lines
end

--- Does this room row match a lowercased filter string?
---
--- Shared between the console list and the window so the two cannot disagree
--- about what "bar" finds. Substring rather than prefix: a room id is
--- `phun.room.2x3_bar` and nobody types the prefix.
function Admin.roomMatches(room, filter)
    if not filter or filter == "" then
        return true
    end
    if string.find(string.lower(room.id), filter, 1, true) then
        return true
    end
    if room.label and string.find(string.lower(room.label), filter, 1, true) then
        return true
    end
    for _, script in ipairs(room.scripts or {}) do
        if string.find(string.lower(script), filter, 1, true) then
            return true
        end
    end
    for _, item in ipairs(room.items or {}) do
        if string.find(string.lower(item), filter, 1, true) then
            return true
        end
    end
    return false
end

--- Every binding, as text.
actions.bindings = function()
    local lines = {}
    for _, binding in ipairs(Admin.bindingState()) do
        local reach = table.concat(binding.scripts, ", ")
        if #binding.items > 0 then
            reach = (reach == "" and "" or reach .. ", ") .. table.concat(binding.items, ", ")
        end
        if binding.matcher then
            reach = (reach == "" and "" or reach .. ", ") .. "a matcher"
        end
        table.insert(lines, string.format("%s (%s, from %s)%s", binding.id, binding.kind,
            binding.source, binding.state == "shipped" and "" or " [overridden]"))
        table.insert(lines, "    " .. (reach == "" and "nothing" or reach) ..
            "  ->  " .. table.concat(binding.rooms, ", "))
    end
    if #lines == 0 then
        table.insert(lines, "no bindings are registered")
    end
    return lines
end

-- Port the calling admin into a room, leasing it to them.
--
--     PhunInteriors.admin("enter", {room = "phun.van.roofed"})
--     PhunInteriors.admin("enter", {room = "phun.van.roofed", index = 9})
actions.enter = function(args, player)
    if not args.room then
        return {"enter needs a room, and optionally an index"}
    end
    local ok, detail = Transit.adminEnter(player, args.room,
        args.index ~= nil and tonumber(args.index) or nil)
    if ok then
        return {"ported into " .. tostring(detail)}
    end
    return {"could not enter: " .. tostring(detail)}
end

-- Hand a slot back, whoever holds it. Straight to quarantine, so the next
-- tenant of that slot gets it scrubbed on arrival.
--
--     PhunInteriors.admin("release", {room = "phun.van.roofed", index = 9})
--     PhunInteriors.admin("release", {vehicleId = "..."})
actions.release = function(args, player)
    local vehicleId = args.vehicleId
    if not vehicleId and args.room and args.index ~= nil then
        local index = tonumber(args.index)
        for id, assignment in pairs(Slots.store().assignments) do
            if assignment.room == args.room and assignment.index == index then
                vehicleId = id
                break
            end
        end
        if not vehicleId then
            return {string.format("%s#%s is not leased to anybody", args.room, tostring(index))}
        end
    end
    if not vehicleId then
        return {"release needs a vehicleId, or a room and an index"}
    end

    -- Somebody standing in it has a lease, a return position and a leash
    -- reading both. Pulling it out from under them would leave the leash
    -- ejecting them to nowhere.
    for key, occupancy in pairs(Core.occupants) do
        if occupancy.vehicleId == vehicleId then
            return {"somebody is inside that room right now (" .. tostring(key) ..
                "); evict them first"}
        end
    end

    -- A safehouse claim makes a room permanent for as long as it stands, and
    -- every other path already respects that: Scrub.slot refuses one,
    -- isReclaimable refuses one, and Slots.acquire skips it. This was the hole
    -- -- an admin reset would drop the lease and quarantine the slot, so the
    -- owner loses the room they claimed and everything in it gets scrubbed
    -- when it is next handed out.
    --
    -- Guarded here rather than inside Slots.release, because that is also how
    -- a vehicle moves between rooms and how removal.lua frees a scrapped
    -- wreck; refusing there would leave a claimed slot leased to a vehicle
    -- that no longer exists.
    local assignment = Slots.find(vehicleId)
    if assignment then
        local claim = Slots.safehouseOn(assignment.room, assignment.index)
        if claim then
            return {string.format("%s#%s is claimed as a safehouse by %s; that claim has to go first",
                assignment.room, tostring(assignment.index), tostring(claim:getOwner()))}
        end
    end

    if Slots.release(vehicleId, "admin") then
        return {"released; it will be scrubbed when it is next handed out"}
    end
    return {"no room is leased to " .. tostring(vehicleId)}
end

actions.scrub = function(args)
    if args.room and args.index then
        local ok, reason = Scrub.slot(args.room, tonumber(args.index))
        return {ok and "scrubbed" or ("could not scrub: " .. tostring(reason))}
    end
    local done = Scrub.processQueue(10)
    return {"scrubbed " .. done .. " quarantined slot(s)"}
end

-- The exit shove, on demand and from wherever you are standing.
--
-- It exists for the same reason admin("reclaim") does: the real trigger needs
-- a set of circumstances that are tedious to arrange. Here that is a crowd
-- standing where a leased vehicle is parked at the moment somebody walks out
-- of its room, and the whole point of the mechanic is that it is over before
-- the player can look at it. This puts the same call in front of a zombie
-- horde an admin can spawn and watch.
--
-- Deliberately the same Transit.shoveZombies the exit calls, rather than its
-- own copy: a test that exercises a second implementation tests nothing.
actions.shove = function(args, player)
    if not player then
        return {"shove needs a player to centre on"}
    end
    local radius = tonumber(args.radius) or Core.settings.ExitShoveRadius or 0
    if radius <= 0 then
        return {"shove radius is 0, so nothing would move; pass {radius = 6} to try it anyway"}
    end
    local moved = Transit.shoveZombies(player:getX(), player:getY(), player:getZ(), radius)
    return {string.format("shoved %d zombie(s) out of %d squares", moved, radius)}
end

actions.evict = function(args)
    local username = args.username
    if not username then
        return {"evict needs a username"}
    end
    local player = Core.tools.getPlayerByUsername(username)
    if not player then
        return {username .. " is not online"}
    end
    local left, why = Transit.leave(player, "admin")
    if left then
        return {"evicted " .. username}
    end
    -- Not always "not inside": the exit refuses a moving vehicle with no free
    -- seat, and a vehicle it cannot place. Reporting those as "not inside"
    -- sends an admin looking for the wrong problem.
    return {"could not evict " .. username .. ": " .. tostring(why)}
end

-- What every captured blueprint weighs. This is the measurement the design
-- note asks for: the estimates there were derived from room dimensions, and
-- nothing had ever been captured to check them against.
actions.manifests = function()
    return Manifest.report()
end

-- Rescan one slot you are standing in. Targets a slot rather than a room
-- because there is no golden slot any more, and a blueprint is only ever as
-- good as the room it was read from.
actions.remanifest = function(args)
    local room = args.room
    local index = tonumber(args.index)
    if not room or not index then
        return {"remanifest needs a room and an index"}
    end
    -- No guard on a shipped blueprint any more. A slot's own capture beats one,
    -- so rescanning is never ignored -- it is how you take a repaint that the
    -- shipped file predates.
    Manifest.forgetSlot(room, index)
    local captured, reason = Manifest.captureSlot(room, index, true)
    if captured then
        local size = Manifest.measure(captured)
        return {string.format("recaptured %s#%s: %d placements, %d sprites in the room's palette",
            room, index, size.placements, size.distinct)}
    end
    return {"could not capture " .. room .. "#" .. index .. ": " .. tostring(reason)}
end

-- ---------------------------------------------------------------------------
-- Editing.
--
-- Every one of these goes through Core.setRoomOverride or
-- Core.setBindingOverride rather than writing Core.rooms directly, for the
-- same reason Transit.adminEnter takes a real lease: a room edited by a path
-- nothing else uses is a room nobody has tested. The patch is stored, the
-- shipped definition is re-registered with it on, and every derived field is
-- rebuilt by registerRoom -- which is what makes a locations edit safe.
--
-- Nothing here writes to disk. `save` does, and it is separate on purpose.
-- ---------------------------------------------------------------------------

--- Change fields on a room.
---
---     PhunInteriors.admin("editRoom", {room = "phun.room.2x3", front = "south"})
---     PhunInteriors.admin("editRoom", {room = "...", clear = {"generator"}})
---     PhunInteriors.admin("editRoom", {room = "...", revert = true})
actions.editRoom = function(args)
    local id = args.room
    if not id then
        return {"editRoom needs a room"}
    end

    if args.revert then
        local existed = Core.rooms[id] ~= nil
        Core.setRoomOverride(id, nil)
        if not existed then
            return {"there is no room called " .. tostring(id)}
        end
        if Core.rooms[id] then
            return {id .. " is back to its shipped definition"}
        end
        return {id .. " was only ever in the override file, and is gone"}
    end

    -- Read through the same validator the file goes through, so a command
    -- typed at the console and a line in PhunInteriors.json are held to
    -- exactly one standard. Anything else means the editor can write a value
    -- the file would refuse, or the reverse.
    local raw = {}
    for key in pairs(Core.roomPatchFields) do
        if args[key] ~= nil then
            raw[key] = args[key]
        end
    end
    if args.clear then
        raw.clear = args.clear
    end

    -- `removeSlots = {3, 7}` is the wire spelling of the file's
    -- `locations = {["3"] = false}` tombstone. Folded into that here and
    -- nowhere else, so there is still exactly one internal representation of
    -- "this slot is deleted and its index stays a gap".
    --
    -- It exists because a table value of `false` has to survive PZ's command
    -- serialisation to get here, and a tombstone that arrived as nil would
    -- read as "this patch does not mention that slot" -- deleting nothing, and
    -- reporting success. A list of numbers cannot fail that way.
    if type(args.removeSlots) == "table" then
        raw.locations = raw.locations or {}
        for _, index in ipairs(args.removeSlots) do
            local n = tonumber(index)
            if n then
                raw.locations[tostring(n)] = false
            end
        end
    end
    if Core.tools.isEmpty(raw) then
        local names = {}
        for key in pairs(Core.roomPatchFields) do
            table.insert(names, key)
        end
        table.sort(names)
        return {"editRoom changes nothing. fields: " .. table.concat(names, ", "),
                "  and clear = {\"front\"}, or revert = true"}
    end

    local patch, problems = Core.readRoomPatch(id, raw)
    if #problems > 0 then
        return problems
    end

    -- Merge onto what is already patched rather than replacing it, so two
    -- commands in a row do not undo each other. The form sends whole
    -- contracts, so this only shows on the console path -- which is where
    -- somebody changes one field at a time.
    local existing = Core.overrides.rooms[id]
    if existing then
        for key, value in pairs(existing) do
            if patch[key] == nil then
                patch[key] = value
            end
        end
    end

    local ok, why = Core.setRoomOverride(id, patch)
    if not ok then
        return {"could not change " .. id .. ": " .. tostring(why)}
    end
    return {id .. " changed; press Save, or PhunInteriors.admin(\"save\"), to keep it"}
end

--- Add, change or drop a binding.
---
---     PhunInteriors.admin("editBinding", {binding = "my.vans",
---         scripts = {"Base.StepVan"}, rooms = {"phun.room.3x4_bar"}})
---     PhunInteriors.admin("editBinding", {binding = "my.vans", remove = true})
actions.editBinding = function(args)
    local id = args.binding
    if not id then
        return {"editBinding needs a binding id"}
    end

    if args.remove then
        Core.setBindingOverride(id, nil)
        -- Said plainly, because a delete that undeletes itself on the next
        -- boot is surprising. The alternative is a tombstone the loader
        -- honours, which is a file that can permanently disable another mod's
        -- binding -- a bigger power than this window should have.
        return {id .. " removed for this session",
                "  a binding registered by lua comes back on the next boot; one made here stays gone"}
    end

    if type(args.rooms) ~= "table" or #args.rooms == 0 then
        return {"editBinding needs rooms = {...}"}
    end
    local missing = {}
    for _, roomId in ipairs(args.rooms) do
        if not Core.rooms[roomId] then
            table.insert(missing, roomId)
        end
    end
    if #missing > 0 then
        -- Refused rather than warned. A binding naming a room that does not
        -- exist is silently dropped by roomsForVehicle's `Core.rooms[roomId]`
        -- test, so it would save, reload and reach nothing, with the window
        -- showing it as bound the whole time.
        return {"no such room: " .. table.concat(missing, ", ")}
    end

    local ok, why = Core.setBindingOverride(id, {
        kind = args.kind == "object" and "object" or "vehicle",
        scripts = args.scripts,
        items = args.items,
        rooms = args.rooms
    })
    if not ok then
        return {"could not change " .. id .. ": " .. tostring(why)}
    end
    return {id .. " bound to " .. table.concat(args.rooms, ", ")}
end

--- Write every change to PhunInteriors.json.
actions.save = function()
    local Store = require "PhunInteriors/store"
    local ok, why = Store.save()
    if not ok then
        return {"could not save: " .. tostring(why)}
    end
    local rooms, bindings = 0, 0
    for _ in pairs(Core.overrides.rooms) do
        rooms = rooms + 1
    end
    for _ in pairs(Core.overrides.bindings) do
        bindings = bindings + 1
    end
    return {string.format("wrote %s: %d room(s), %d binding(s)", Store.FILE, rooms, bindings)}
end

--- Throw away everything unsaved and re-read the file.
---
--- Deliberately not called `reload`: that name is taken, by the action that
--- re-reads the sandbox options, and one word meaning both "re-read the
--- settings" and "discard my edits" is a mistake somebody makes exactly once.
actions.revertAll = function()
    local Store = require "PhunInteriors/store"
    local rooms, problems = Store.reload()
    local lines = {string.format("re-read %s: %d room(s) customised", Store.FILE, rooms)}
    for _, complaint in ipairs(problems) do
        table.insert(lines, "  " .. complaint)
    end
    return lines
end

-- player is passed through because some actions are about the caller rather
-- than about the world: porting into a room puts *you* in it, and the room
-- list marks the slot *you* hold. Actions that do not care simply ignore it.
function Admin.run(action, args, player)
    local handler = actions[action]
    if not handler then
        local names = {}
        for name in pairs(actions) do
            table.insert(names, name)
        end
        table.sort(names)
        return {"unknown action. try: " .. table.concat(names, ", ")}
    end
    local ok, result = pcall(handler, args, player)
    if not ok then
        Core.logLn("admin action " .. tostring(action) .. " failed: " .. tostring(result))
        return {"that failed, check the server log"}
    end
    return result
end

--- Soft hook into PhunServer2 if it happens to be loaded.
function Admin.registerChatCommands()
    if not PhunServer2 or not PhunServer2.registerCommand then
        Core.debugLn("PhunServer2 not present, skipping chat command registration")
        return false
    end

    PhunServer2.registerCommand("interiors", {
        adminOnly = true,
        help = function()
            return getText("IGUI_PhunInteriors_AdminUsage")
        end,
        action = function(player, arguments)
            local parts = {}
            for word in string.gmatch(arguments or "", "%S+") do
                table.insert(parts, word)
            end
            local result = Admin.run(parts[1] or "list", {
                vehicleId = parts[2],
                room = parts[2],
                index = parts[3],
                username = parts[2],
                radius = parts[2]
            }, player)
            for _, line in ipairs(result) do
                Core.logLn(line)
            end
            return result
        end
    })

    Core.logLn("registered /interiors with PhunServer2")
    return true
end

return Admin
