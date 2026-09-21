require "PhunInteriors/core"
require "PhunInteriors/tools"
local Core = PhunInteriors
local tools = Core.tools

-- ---------------------------------------------------------------------------
-- What the admin editor changed, and how it is put back on.
--
-- The registry is code. `defaults.lua` is GENERATED from three CSVs by
-- Docs/gendefaults.pl, so an edit written back into it is lost on the next run
-- and an edit written anywhere else in the lua needs a redeploy and a restart.
-- Neither is a loop an admin can run while standing in the room being fixed.
--
-- So an edit is a PATCH, kept beside the shipped registration rather than
-- inside it, in PhunInteriors.json in the game's Lua folder. Three states fall
-- out of that and the editor shows all three:
--
--     shipped      registered by lua, no patch          -- stock
--     overridden   registered by lua, and patched       -- customised
--     new          in the file and nowhere else         -- the admin made it
--
-- Sparse, and that is the whole design rather than a saving. A patch naming
-- only what differs means a room whose shipped definition changes in a later
-- version picks the change up everywhere the admin did not have an opinion. A
-- file holding whole rooms would pin all of it: re-export the map, ship a new
-- `front`, and the admin's copy would quietly keep the old one on every room
-- they had ever opened -- including the fields they never looked at.
--
-- APPLYING ONE RE-RUNS registerRoom. It is tempting to write the fields
-- straight onto Core.rooms[id], and that is wrong for `locations`: the built
-- room carries `slots`, `indices` and `count` derived from them, so a patch
-- writing locations alone would leave three derived fields describing the old
-- set. Re-registering from a merged definition gets all of that from the one
-- piece of code that knows how to do it, gets the validation and the warnings
-- for free, and cannot drift from what a boot-time registration produces --
-- because it IS one.
--
-- Which is why `Core.roomDefs` exists: the raw definition as first registered,
-- deep copied before anything is applied. Revert rebuilds from it.
-- ---------------------------------------------------------------------------

--- Every room field a patch may carry, and how to read it out of JSON.
--
-- An explicit list rather than "whatever keys the patch has", because the file
-- is hand editable and a typo would otherwise become a silent no-op: a patch
-- saying `"fron": "south"` would be copied onto the definition, ignored by
-- registerRoom, and read back by the editor as a room with no front. Named
-- fields mean an unknown key can be reported.
--
-- `kind` is what the value must be for the patch to be worth applying. Nothing
-- here coerces: a bad value is refused and said out loud, because the one
-- lesson this mod keeps relearning is that a wrong value which looks
-- deliberate costs more than a missing one.
Core.roomPatchFields = {
    label = {kind = "string"},
    priority = {kind = "number"},
    size = {kind = "size"},
    spawn = {kind = "spawn"},
    front = {kind = "edge"},
    cab = {kind = "boolean"},
    generator = {kind = "offset"},
    selfPowered = {kind = "boolean"},
    singleUse = {kind = "boolean"},
    reservoir = {kind = "boolean"},
    baseWeight = {kind = "number"},
    locations = {kind = "locations"}
}

--- The edges `front` may name. Registry has its own copy for RELATIVE; this
--- one is for validating a patch before registerRoom ever sees it, so the
--- editor can refuse a bad edge rather than logging a warning at boot.
local EDGES = {
    north = true,
    south = true,
    east = true,
    west = true
}

local function warn(text)
    Core.logLn("overrides: " .. text)
end

---------------------------------------------------------------------------
-- Reading a patch
---------------------------------------------------------------------------

--- Is `value` a plausible value for a field of this kind?
--- @return the value to use, or nil plus why not
local function checkValue(kind, value)
    if kind == "string" then
        if type(value) ~= "string" then
            return nil, "must be text"
        end
        return value
    elseif kind == "number" then
        local n = tonumber(value)
        if not n then
            return nil, "must be a number"
        end
        return n
    elseif kind == "boolean" then
        if type(value) ~= "boolean" then
            return nil, "must be true or false"
        end
        return value
    elseif kind == "edge" then
        if type(value) ~= "string" or not EDGES[value] then
            return nil, "must be north, south, east or west"
        end
        return value
    elseif kind == "size" then
        if type(value) ~= "table" or not tonumber(value.w) or not tonumber(value.h) then
            return nil, "must be {w = , h = }"
        end
        if tonumber(value.w) < 1 or tonumber(value.h) < 1 then
            return nil, "must be at least 1 x 1"
        end
        return {w = math.floor(tonumber(value.w)), h = math.floor(tonumber(value.h))}
    elseif kind == "spawn" then
        if type(value) ~= "table" or not tonumber(value.x) or not tonumber(value.y) then
            return nil, "must be {x = , y = }"
        end
        return {x = math.floor(tonumber(value.x)), y = math.floor(tonumber(value.y))}
    elseif kind == "offset" then
        if type(value) ~= "table" or not tonumber(value.x) or not tonumber(value.y) then
            return nil, "must be {x = , y = , z = }"
        end
        return {
            x = math.floor(tonumber(value.x)),
            y = math.floor(tonumber(value.y)),
            z = math.floor(tonumber(value.z) or 0)
        }
    elseif kind == "locations" then
        -- Keyed by SLOT INDEX as a string, because JSON object keys are
        -- strings and this module is the one place that conversion happens.
        -- The index is the identity a lease persists, so it is carried rather
        -- than re-derived from position in a list.
        --
        -- A value of `false` is a TOMBSTONE: it deletes that slot and leaves a
        -- GAP. That is not a nicety -- closing the gap up would renumber every
        -- slot after it and re-point every lease beyond the change at somebody
        -- else's room. normaliseLocations sorts pairs() keys precisely so a
        -- gap is expressible.
        if type(value) ~= "table" then
            return nil, "must be a table of slot index -> position"
        end
        local out = {}
        for key, entry in pairs(value) do
            local index = tonumber(key)
            if not index or index < 0 or index ~= math.floor(index) then
                return nil, "'" .. tostring(key) .. "' is not a slot index"
            end
            if entry == false then
                out[index] = false
            elseif type(entry) == "table" then
                local x = tonumber(entry.x or entry[1])
                local y = tonumber(entry.y or entry[2])
                if not x or not y then
                    return nil, "slot " .. index .. " has no position"
                end
                out[index] = {math.floor(x), math.floor(y), math.floor(tonumber(entry.z or entry[3]) or 0)}
            else
                return nil, "slot " .. index .. " must be a position or false"
            end
        end
        return out
    end
    return nil, "unknown field kind " .. tostring(kind)
end

Core.checkPatchValue = checkValue

--- Read one room patch out of decoded JSON, dropping what does not make sense.
--
-- Drops rather than refuses the whole patch, and says so for each one. A file
-- with one bad line in it should apply the other twenty, because the
-- alternative is an admin losing every customisation to a typo in one.
--
-- @return the patch, and a list of complaints
function Core.readRoomPatch(id, raw)
    local patch, problems = {}, {}
    if type(raw) ~= "table" then
        return nil, {id .. ": not a table"}
    end

    for key, value in pairs(raw) do
        if key == "clear" then
            -- How a patch says "this room has NO front" as opposed to "this
            -- patch has nothing to say about its front". JSON null cannot do
            -- it: the parser returns nil for null and a nil value in a Lua
            -- table is simply an absent key, so the two are the same thing on
            -- the way in. A list of field names says it unambiguously.
            --
            -- It matters most for `generator` and `front`, the two fields
            -- whose whole contract is that nil means something -- no power,
            -- and no stated facing. Without this an admin could add a
            -- generator to a room and never take it away again.
            if type(value) ~= "table" then
                table.insert(problems, id .. ": 'clear' must be a list of field names")
            else
                patch.clear = {}
                for _, name in ipairs(value) do
                    if Core.roomPatchFields[name] then
                        patch.clear[name] = true
                    else
                        table.insert(problems, id .. ": cannot clear unknown field '" .. tostring(name) .. "'")
                    end
                end
            end
        else
            local field = Core.roomPatchFields[key]
            if not field then
                table.insert(problems, id .. ": unknown field '" .. tostring(key) .. "'")
            else
                local ok, why = checkValue(field.kind, value)
                if ok == nil then
                    table.insert(problems, id .. "." .. key .. ": " .. why)
                else
                    patch[key] = ok
                end
            end
        end
    end

    return patch, problems
end

---------------------------------------------------------------------------
-- Merging
---------------------------------------------------------------------------

--- Shipped definition plus patch, ready to hand to registerRoom.
---
--- Returns nil when the room has no shipped definition and the patch is not a
--- whole one -- which is how a file naming a room that no longer exists is
--- caught, rather than by registering a room with no size.
function Core.mergedRoomDef(id)
    local base = Core.roomDefs[id]
    local patch = Core.overrides.rooms[id]
    if not patch then
        return base and tools.deepCopy(base) or nil
    end

    local def = base and tools.deepCopy(base) or {}

    for key in pairs(Core.roomPatchFields) do
        if patch.clear and patch.clear[key] then
            def[key] = nil
        elseif patch[key] ~= nil and key ~= "locations" then
            def[key] = tools.deepCopy(patch[key])
        end
    end

    -- Locations merge entry by entry rather than replacing the table, so a
    -- patch that moves one stamp does not have to restate the other fifty-nine
    -- -- and, more to the point, cannot silently drop them by omission.
    if patch.locations and not (patch.clear and patch.clear.locations) then
        def.locations = def.locations or {}
        local merged = {}
        for index, entry in pairs(def.locations) do
            local n = tonumber(index)
            if n then
                merged[n] = entry
            end
        end
        for index, entry in pairs(patch.locations) do
            if entry == false then
                merged[index] = nil
            else
                merged[index] = entry
            end
        end
        def.locations = merged
    end

    return def
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

-- Set while registerRoom is being re-entered to apply a patch, so the
-- re-entry does not snapshot the patched definition as the shipped one and
-- does not warn about a redefinition nobody asked for.
--
-- A flag rather than a parameter because registerRoom is public API: a third
-- party calls it, and an extra argument they do not pass would read as nil and
-- work, right up until somebody passed something in it by accident.
local applying = false

--- True while an override is being put back on. registry.lua reads this.
function Core.isApplyingOverride()
    return applying
end

--- Remember the definition `id` was registered with, unless we are the ones
--- registering it. Called by registerRoom before it builds anything.
function Core.snapshotRoomDef(id, def)
    if applying then
        return
    end
    Core.roomDefs[id] = tools.deepCopy(def)
end

--- Re-register `id` from its shipped definition plus whatever patch it has.
---
--- Safe to call when there is no patch: it rebuilds from the snapshot, which
--- is how revert works and is a no-op in every other sense.
--- @return true if the room now exists
function Core.applyRoomOverride(id)
    if applying then
        return false
    end
    local def = Core.mergedRoomDef(id)
    if not def then
        return false
    end
    if not def.size or not def.locations then
        warn("'" .. id .. "' has no shipped definition and the patch is not a whole room; ignoring it")
        return false
    end

    applying = true
    -- pcall, because this is reached from a command handler on a live server
    -- and a malformed patch that threw would take the handler with it. The
    -- room is left as it was: registerRoom writes Core.rooms[id] in one
    -- statement at the end, after everything that can fail.
    local ok, err = pcall(Core.registerRoom, id, def)
    applying = false

    if not ok then
        warn("could not apply the patch for '" .. id .. "': " .. tostring(err))
        return false
    end
    return Core.rooms[id] ~= nil
end

--- Which of the three states `id` is in.
function Core.roomOverrideState(id)
    if not Core.roomDefs[id] then
        return "new"
    end
    if Core.overrides.rooms[id] then
        return "overridden"
    end
    return "shipped"
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

--- Store a patch for `id` and put it on. Pass nil to revert to shipped.
---
--- The patch is diffed against the shipped definition first and anything that
--- matches is dropped, so an admin who opens the form and presses Apply
--- without changing anything leaves no entry behind. Without that the file
--- fills with rooms that read as customised and are not, and the editor's
--- three states stop meaning anything.
--- @return true, or false plus why not
function Core.setRoomOverride(id, patch)
    if type(id) ~= "string" or id == "" then
        return false, "a room needs an id"
    end

    -- Marked before anything can fail. A half applied edit is still an edit
    -- the registry is carrying that the file is not, which is exactly what the
    -- flag is for.
    Core.unsavedEdits = true

    if patch == nil then
        if not Core.roomDefs[id] then
            -- Nothing to fall back to: this room exists only because the file
            -- says so, and reverting it means deleting it.
            Core.overrides.rooms[id] = nil
            Core.rooms[id] = nil
            Core.markRegistryDirty()
            return true
        end
        Core.overrides.rooms[id] = nil
        Core.applyRoomOverride(id)
        return true
    end

    local base = Core.roomDefs[id]
    local trimmed = {}
    local kept = false
    for key, value in pairs(patch) do
        if key == "clear" then
            -- A clear only means anything where the shipped definition had
            -- something to clear. Counted separately from `kept`, because a
            -- shared flag would attach an empty clear table to any patch that
            -- happened to change something else -- and the form sends a
            -- `clear` list on every apply, so that would be most of them.
            local clear = {}
            local clearing = false
            for name in pairs(value) do
                if not base or base[name] ~= nil then
                    clear[name] = true
                    clearing = true
                end
            end
            if clearing then
                trimmed.clear = clear
                kept = true
            end
        elseif base == nil or not tools.deepEquals(value, base[key]) then
            trimmed[key] = tools.deepCopy(value)
            kept = true
        end
    end

    Core.overrides.rooms[id] = kept and trimmed or nil
    if not Core.applyRoomOverride(id) then
        return false, "the room could not be rebuilt with that change"
    end
    return true
end

--- Store a binding and put it on, or pass nil to drop it.
---
--- Bindings are replaced whole rather than patched, and that is not laziness:
--- a binding is two lists, and "patch a list" has no good meaning -- an entry
--- removed by omission and a list not mentioned look identical. Core.bindings
--- is keyed by id and registerVehicles already replaces, so whole is also what
--- the registry itself does.
function Core.setBindingOverride(id, def)
    if type(id) ~= "string" or id == "" then
        return false, "a binding needs an id"
    end

    Core.unsavedEdits = true

    if def == nil then
        Core.overrides.bindings[id] = nil
        Core.bindings[id] = nil
        Core.markRegistryDirty()
        -- A shipped binding comes back on the next boot, when its lua runs
        -- again. Saying so, because "delete" that undeletes itself is
        -- surprising and the alternative -- a tombstone the loader honours --
        -- means a file that can permanently disable another mod's binding.
        return true
    end

    Core.overrides.bindings[id] = tools.deepCopy(def)
    return Core.applyBindingOverride(id)
end

--- (Re)register one binding out of the override table.
function Core.applyBindingOverride(id)
    local def = Core.overrides.bindings[id]
    if not def then
        return false, "no such binding"
    end

    local payload = {
        id = id,
        rooms = def.rooms or {},
        scripts = def.scripts,
        items = def.items,
        source = def.source or "PhunInteriors.json"
    }

    -- Which register call decides the binding's KIND, and the kind is what
    -- decides whose predicate is shown what -- see roomsForVehicle. So it is
    -- read off the definition rather than guessed from which list happens to
    -- be filled, because a binding that is nothing but a matcher names
    -- neither and that is a legitimate shape.
    local ok, err
    if def.kind == "object" then
        ok, err = pcall(Core.registerObjects, payload)
    else
        ok, err = pcall(Core.registerVehicles, payload)
    end
    if not ok then
        warn("could not apply the binding '" .. id .. "': " .. tostring(err))
        return false, tostring(err)
    end
    return true
end

---------------------------------------------------------------------------
-- The document
---------------------------------------------------------------------------

--- Everything the editor has changed, shaped for json.encodePretty.
---
--- Slot indices become strings here and nowhere else. They are numbers
--- everywhere inside the mod, because that is what a lease persists, and JSON
--- object keys must be strings -- so the conversion belongs at the boundary,
--- once, rather than in each caller that remembers.
function Core.overrideDocument()
    local doc = {
        version = 1,
        rooms = {},
        bindings = {}
    }

    for id, patch in pairs(Core.overrides.rooms) do
        local out = {}
        for key, value in pairs(patch) do
            if key == "locations" then
                local locations = {}
                for index, entry in pairs(value) do
                    locations[tostring(index)] = entry
                end
                out.locations = locations
            elseif key == "clear" then
                local clear = {}
                for name in pairs(value) do
                    table.insert(clear, name)
                end
                table.sort(clear)
                out.clear = clear
            else
                out[key] = tools.deepCopy(value)
            end
        end
        doc.rooms[id] = out
    end

    for id, def in pairs(Core.overrides.bindings) do
        doc.bindings[id] = tools.deepCopy(def)
    end

    return doc
end

--- Install a decoded document and put every patch in it on.
---
--- Rooms the registry already knows are patched. Rooms it does not are
--- REGISTERED from the file, which is how an admin adds one without a
--- redeploy -- and is why a patch for a room nobody registered is not an error
--- as long as it is a whole room.
--- @return a list of complaints, empty when the file read cleanly
function Core.installOverrides(doc)
    local problems = {}
    Core.overrides.rooms = {}
    Core.overrides.bindings = {}

    if type(doc) ~= "table" then
        return {"the override file does not contain a JSON object"}
    end

    for id, raw in pairs(doc.rooms or {}) do
        local patch, why = Core.readRoomPatch(id, raw)
        for _, complaint in ipairs(why or {}) do
            table.insert(problems, complaint)
        end
        if patch then
            Core.overrides.rooms[id] = patch
        end
    end

    for id, def in pairs(doc.bindings or {}) do
        if type(def) ~= "table" then
            table.insert(problems, "binding '" .. id .. "': not a table")
        else
            Core.overrides.bindings[id] = tools.deepCopy(def)
        end
    end

    -- Applied after the whole file is read, so a binding naming a room the
    -- file also creates resolves whichever order pairs() walked them in.
    for id in pairs(Core.overrides.rooms) do
        if not Core.applyRoomOverride(id) then
            table.insert(problems, "'" .. id .. "' could not be applied")
        end
    end
    for id in pairs(Core.overrides.bindings) do
        local ok, why = Core.applyBindingOverride(id)
        if not ok then
            table.insert(problems, "binding '" .. id .. "': " .. tostring(why))
        end
    end

    return problems
end

return Core
