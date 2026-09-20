require "PhunInteriors/core"
require "PhunInteriors/holders"
-- Core.snapshotRoomDef and Core.isApplyingOverride, which registerRoom calls.
-- Not a cycle: overrides.lua needs core and tools at load time and this file's
-- register calls only at run time.
--
-- There used to be a `require "PhunInteriors/tools"` above this for
-- Core.tools.isEmpty, which Core.roomAllows used to test a room's `requires`.
-- Both are gone and nothing in this file calls Core.tools any more; overrides
-- pulls tools in for itself.
require "PhunInteriors/overrides"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Rooms and their vehicle bindings are registered, not hard coded. Other mods
-- do exactly what defaults.lua does: hook OnRegisterRooms or
-- OnRegisterVehicles and call these functions. Ids are namespaced author.name
-- so two mods cannot collide.
--
-- A ROOM is a CONTRACT: one shape, one spawn tile, which edge faces the front
-- of whatever carries it, one generator offset -- and every place on the map
-- it is stamped. Two rooms whose contract differs are two registrations.
--
-- A room states nothing about WHAT may carry it. That is the binding's answer,
-- and the one attempt to say it room-side as well (`requires`) is gone; see
-- the note where Core.roomAllows used to be.
--
-- What a room deliberately does NOT fix is what is on the squares. Wallpaper,
-- carpet, overlays and fittings are captured in game, per slot, on first
-- lease, so a map author can decorate the stamps differently and each is
-- restored to what they actually built there. Opinionated about the shape,
-- indifferent to the decor.
--
-- A SLOT is one stamped instance, identified by its index. The index is the
-- identity a lease persists, so it outlives the list it was written in, and it
-- is what a captured blueprint is filed under.
--
-- A BINDING says which vehicles may lease which rooms, and it names game
-- SCRIPTS rather than ids of ours. That is what makes a second direction
-- unnecessary: a map pack shipping van rooms writes
-- {scripts = {"Base.StepVan"}, rooms = {"theirmod.vanrooms"}}, and a car mod
-- shipping a van writes {scripts = {"TheirVan"}, rooms = {"phun.van.roofed"}}.
-- Both parties know a vanilla script name without having to ask anybody, and
-- neither has to know an id of the other's. Bindings are unioned when the
-- reverse index is built, so whoever ships second still gets a say.
-- ---------------------------------------------------------------------------

local function warn(str)
    Core.logLn("registry: " .. str)
end

-- Set to true by every register* call and cleared by the first read after it.
-- Deferring the rebuild is what makes registration order stop mattering: a mod
-- can register on either register event, on OnReady, or from an admin command
-- ten minutes into the session, and none of them has to know which of the
-- others ran first.
local dirty = true

--- Say the reverse indexes need rebuilding.
---
--- The flag is file local and every register call sets it, which covered
--- everything until the admin editor learned to DELETE. A room or a binding
--- removed from Core.rooms/Core.bindings by hand leaves the indexes naming it,
--- so the next allocation offers a room that is no longer there -- and
--- Core.slotOrigin returns nil for it, which Slots.acquire reads as a stale
--- lease and releases. The symptom is a vehicle losing its room on entry.
---
--- Deliberately not exposing `dirty` itself. A writable flag is a second way
--- to say this, and somebody would eventually clear it.
function Core.markRegistryDirty()
    dirty = true
end

-- Forward declared, because the lookups below call it and the reverse index
-- section that defines it has to come after the geometry helpers it uses. A
-- `local function` further down would not be in scope up here -- it would
-- resolve as a global and be nil at runtime.
local indexed

--- Turn the author's `locations` into an explicit index -> position map.
--
-- The index is the slot's identity and is what a lease persists, so a location
-- table is keyed by it rather than merely ordered. Appending is safe;
-- renumbering re-points every lease after the change at somebody else's room,
-- and deleting a location must leave a GAP rather than close one up.
--
-- Which is why this collects keys with pairs and sorts them, instead of
-- counting up from zero until it finds a nil. Counting up is what it used to
-- do, and it stopped dead at the first gap: deleting location 12 of 50
-- silently deleted 13..49 as well, `count` reported 11, and the room set
-- quietly shrank with no warning anywhere. A sparse set is legal.
--
-- An entry is {x, y, z} or {x = , y = , z = }. Positional is what the grid
-- helpers emit and what reads at a hundred rows; named is what somebody hand
-- writing a couple of them reaches for. Both mean the same thing.
local function normaliseLocations(id, def)
    local slots, indices = {}, {}

    local function add(index, entry)
        if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then
            warn("room '" .. id .. "' has a location keyed by " .. tostring(index) ..
                     ", which is not a slot index")
            return
        end
        if slots[index] then
            warn("room '" .. id .. "' defines location " .. index .. " more than once")
            return
        end
        local x = entry.x or entry[1]
        local y = entry.y or entry[2]
        local z = entry.z or entry[3] or 0
        if not tonumber(x) or not tonumber(y) then
            warn("room '" .. id .. "' location " .. index .. " has no position")
            return
        end
        slots[index] = {
            x = math.floor(x),
            y = math.floor(y),
            z = math.floor(z)
        }
        table.insert(indices, index)
    end

    for index, entry in pairs(def.locations or {}) do
        if type(entry) == "table" then
            add(index, entry)
        end
    end

    table.sort(indices)
    return slots, indices
end

--- The opposite edge, and the two perpendicular ones named from the holder's
--- own point of view.
--
-- Facing east, your left hand points north. That is the whole table; it is
-- written out rather than computed because four rows are cheaper to check by
-- eye than a rotation nobody can verify without a compass.
local RELATIVE = {
    north = {rear = "south", left = "west", right = "east"},
    south = {rear = "north", left = "east", right = "west"},
    east = {rear = "west", left = "north", right = "south"},
    west = {rear = "east", left = "south", right = "north"}
}

--- An edge name, or nil plus a warning if it is not one.
local function normaliseEdge(id, edge)
    if edge == nil then
        return nil
    end
    if type(edge) == "string" and RELATIVE[edge] then
        return edge
    end
    warn("room '" .. id .. "' has front = " .. tostring(edge) ..
             ", which is not an edge; ignoring it")
    return nil
end

--- Where a tenant leaving by `edge` comes out, relative to the holder.
--
-- "front", "rear", "left" or "right", or nil when the room never said which
-- way its holder points -- in which case there is nothing to be relative TO
-- and the tenant lands beside the vehicle, exactly as every room did before
-- any of this existed.
--
-- This is the arithmetic that let the `landing` table go. The room states one
-- fact about itself and every edge's answer follows, so an author can no
-- longer name a vehicle part that is not where their door is.
function Core.relativeFor(room, edge)
    local front = room and room.front
    if not front or not edge then
        return nil
    end
    if edge == front then
        return "front"
    end
    local map = RELATIVE[front]
    if not map then
        return nil
    end
    for name, other in pairs(map) do
        if other == edge then
            return name
        end
    end
    return nil
end

--- Register one room design and every place it is stamped.
-- @param id namespaced id, eg "phun.van.roofed"
-- @param def size/spawn/front/cab/generator/selfPowered/reservoir/baseWeight/
--        label/priority, plus locations
function Core.registerRoom(id, def)
    if type(id) ~= "string" or not def then
        warn("registerRoom needs an id and a definition")
        return
    end
    if not def.size then
        warn("room '" .. id .. "' needs a size")
        return
    end
    if not def.locations then
        warn("room '" .. id .. "' needs locations")
        return
    end

    -- Applying an admin override re-enters here with the shipped definition
    -- plus a patch, which is a redefinition in the letter and not in the
    -- spirit: it is how a locations edit gets `slots`, `indices` and `count`
    -- re-derived by the code that owns that arithmetic. So the warning is
    -- skipped for it, and so is the snapshot -- taking one would record the
    -- patched definition as the shipped one and there would be nothing left to
    -- revert to.
    local reapplying = Core.isApplyingOverride()

    if Core.rooms[id] and not reapplying then
        -- There is no append. Re-registering replaces, so an author "adding"
        -- rooms this way would delete the stock ones out from under live
        -- leases; their own id plus a binding is the supported path.
        warn("room '" .. id .. "' is being redefined")
    end

    local slots, indices = normaliseLocations(id, def)
    if #indices == 0 then
        warn("room '" .. id .. "' ended up with no locations")
        return
    end

    Core.rooms[id] = {
        id = id,
        label = def.label or id,
        -- index -> {x, y, z}, and the indices in order. The index is the slot's
        -- identity and is what a lease persists, so it outlives the list.
        slots = slots,
        indices = indices,
        -- highest index rather than how many, kept because it reads in a log
        -- line and because a sparse set has no single sensible "count"
        count = indices[#indices],
        -- Which of two equally specialised rooms to hand out first. Lower goes
        -- first; default 0. Only a preference -- specificity still wins over
        -- it, because that one prevents starvation and this one only expresses
        -- that some rooms are nicer than others.
        priority = tonumber(def.priority) or 0,
        size = {
            w = def.size.w,
            h = def.size.h
        },
        spawn = {
            x = (def.spawn and def.spawn.x) or 1,
            y = (def.spawn and def.spawn.y) or 1
        },
        -- Which EDGE of the room faces the FRONT of whatever is carrying it.
        --
        --     front = "south", cab = true
        --
        -- One edge, and every other destination falls out of it as arithmetic:
        -- the opposite edge is the rear and the two perpendicular ones are the
        -- sides. Core.relativeFor is that sum.
        --
        -- This replaced a `landing` table mapping each edge to a VEHICLE SCRIPT
        -- AREA NAME -- landing = {north = "TruckBed", south = "cab"} -- and two
        -- things were wrong with it, only one of them obvious.
        --
        -- It put vehicle vocabulary in the room contract, so a room carried by
        -- anything else had no way to answer. That is the category error
        -- `requires` made, which is why that field no longer exists at all.
        --
        -- And it made authors lie. Across the whole shipped map the deployed
        -- vocabulary was "TruckBed" and "cab", and two of those TruckBeds sat
        -- on an EAST or WEST door -- the camper vans and the caravans, whose
        -- door is in the side. A side door does not lead to the truck bed; the
        -- name was standing in for "outward" because it was the only area that
        -- resolved to a sane direction. Saying which way the holder points says
        -- the true thing once instead of the false thing per edge.
        --
        -- Resolved client side, because the vehicle is not loaded when its
        -- tenant leaves: the direction rides down with the teleport and the
        -- client asks the real vehicle once the chunk has streamed in.
        --
        -- NO DEFAULT, for the reason `generator` has none: a room whose long
        -- axis ran east-west would be handed a wrong answer that looks
        -- deliberate. A room that says nothing here lands its tenant beside the
        -- vehicle exactly as every room did before any of this existed.
        front = normaliseEdge(id, def.front),
        -- Whether the FRONT edge puts you in a seat rather than on the ground.
        --
        -- A boolean rather than an edge of its own, because a cab is always at
        -- the front of the thing -- across the whole shipped map there was
        -- never a seat exit anywhere else. Two fields would have been two ways
        -- to say one fact, and they could disagree.
        --
        -- It is the one destination that can FAIL, and only the client can see
        -- it fail: whether a seat is free is a question about a vehicle that is
        -- not loaded when its tenant leaves. So a cab exit is a REQUEST. The
        -- client reports `seated` back on the arrival handshake and
        -- Transit.arrived puts them back in the room when it is false.
        cab = def.cab == true,
        -- Where the generator lives, as an offset from the slot origin, and
        -- deliberately outside the leash so it is reached through a panel and
        -- never on foot. Being outside the room is also why it makes no fumes:
        -- vanilla only makes a building toxic for a generator on a
        -- non-exterior square, and nobody ever stands next to this one.
        --
        -- NIL MEANS NO GENERATOR, and there is deliberately no default. A tent
        -- says nothing here and gets nothing conjured for it, which is what
        -- the old `powered = false` flag was for -- two fields to say one
        -- thing, and the *other* one was the trap. `power` used to default to
        -- {0, 0, 1}; carried over from a borrowed set it made
        -- Power.ensureGenerator look one level above the room, find nothing,
        -- and build a generator on every roof while fifty good ones sat 17
        -- tiles south. A wrong position fails silently and self-heals into
        -- looking deliberate, so the only safe default is none.
        generator = def.generator,
        -- Whether this room's generator needs no external supply.
        --
        -- Omitted, the supply is derived from whatever holds the lease: a
        -- vehicle pays out of its battery, a world object out of a generator
        -- its owner parked nearby, and a player-keyed lease -- an admin port,
        -- a spawn room -- pays nothing because there is nothing to charge.
        -- That derivation is right for everything except a room you DRIVE to
        -- and still want lit for free, which is what this says.
        --
        -- It does NOT conjure power. haveElectricity() reads no field: it is
        -- chunk:isGeneratorPoweringSquare, so a lit room always has a real
        -- activated IsoGenerator at `generator` whatever this is set to. All
        -- this suppresses is the fuel ledger.
        --
        -- Deliberately NOT called `powered`: that name is already taken, by the
        -- admin payload field meaning "room.generator ~= nil", which is on
        -- screen in the room list as "powered" / "no generator". One word
        -- meaning both "has a generator" and "has a free one" is how a reader
        -- ends up confidently wrong.
        selfPowered = def.selfPowered == true,
        -- There is deliberately no `requires`. A def carrying one is ignored
        -- rather than refused, so an old third party room set still loads;
        -- see the note above Core.vehicleMotionAllows for why it went.
        --
        -- Whether a rain reservoir kit may be installed here. On unless the
        -- room says otherwise; a tent says `reservoir = false`.
        --
        -- The one contract field that defaults ON, and the reasoning that gave
        -- `generator` no default does not carry over. That was a POSITION an
        -- author had to supply, and a wrong one self-healed into something
        -- that looked deliberate. Nothing here is a position: where the
        -- barrels go is derived from the floor, and Core.reservoirPlan refuses
        -- any spot that is not an outdoor roof square with nothing solid on
        -- it. A room whose author never heard of this field refuses visibly
        -- rather than growing barrels somewhere wrong.
        reservoir = def.reservoir ~= false,
        -- What the fitted-out room weighs before anybody puts anything in it.
        -- The blueprint's own fixtures are deliberately not charged for -- they
        -- are always there, so billing them per item would just be a flat tax
        -- with a confusing derivation. This says the same thing once, as a
        -- number the author picked.
        baseWeight = tonumber(def.baseWeight) or 0,
        source = def.source or "unknown"
    }

    -- Said after the room is built, not before, so the warning names a room
    -- that exists and an admin can go and look at it. Neither of these refuses
    -- the registration: both leave a room that works and merely does less than
    -- its author meant, which is better than a map with a hole in it.
    local room = Core.rooms[id]
    if room.cab and not room.front then
        -- A cab is the front edge putting you in a seat. With no front edge
        -- there is no edge for it to be, so the flag means nothing at all --
        -- and it fails by silently behaving as though it had never been set.
        warn("room '" .. id .. "' says cab but never says which edge is its " ..
                 "front, so no exit can reach a seat")
    end
    if room.selfPowered and not room.generator then
        -- The trap this exists to catch: haveElectricity() is only ever a real
        -- activated IsoGenerator in the chunk, so a room claiming free power
        -- with nowhere to put a generator is simply dark. Nothing downstream
        -- can tell that from a room that was meant to be dark.
        warn("room '" .. id .. "' says selfPowered but declares no generator, " ..
                 "so it has no power at all")
    end

    -- Snapshotted here rather than on the way in, so a definition that failed
    -- one of the returns above is not recorded as this room's shipped state --
    -- which would leave the editor offering a revert to something that never
    -- registered. What is kept is the definition the AUTHOR passed, not the
    -- normalised `room` built from it, because applying a patch re-enters this
    -- function and a def is what it takes.
    --
    -- A no-op while an override is being applied; see overrides.lua.
    Core.snapshotRoomDef(id, def)

    dirty = true
    Core.debugLn("registered room " .. id .. " (" .. #indices .. " locations)")

    -- Put the admin's patch back on, if this room has one.
    --
    -- Here rather than in a pass after registration is complete, for the same
    -- reason the reverse indexes rebuild lazily: registration is never
    -- complete. A third party is free to register from any vanilla hook, which
    -- can land long after our boot sequence, and a room that turned up late
    -- would otherwise be the one room in the set the admin's edits did not
    -- reach -- silently, because it would look registered and correct.
    --
    -- Recursion is not a risk: applyRoomOverride re-enters this function with
    -- the `applying` flag set, and returns immediately when it is already set.
    if not reapplying and Core.overrides.rooms[id] then
        Core.applyRoomOverride(id)
        -- Re-read, because the room the patch built is a different table from
        -- the one above and a caller keeping the return value would be holding
        -- the unpatched one.
        return Core.rooms[id]
    end

    return room
end

--- Say which vehicles may lease which rooms.
--
-- @param def rooms, plus scripts and/or match, plus an optional id
--
-- Bindings are keyed by id, so re-registering your own replaces it -- which is
-- what you want when you are editing your own file. What is NEVER replaced is
-- another author's: the script -> rooms answer is unioned across every
-- binding when the index is built, so a map pack naming "Base.StepVan" adds
-- its rooms to the ones our own binding already offers rather than taking the
-- vehicle over.
--
-- `id` exists so the sandbox script-override option has something to name and
-- so a log line can say who bound what. It is optional; without one the source
-- and an ordinal stand in.
local anonymous = 0
function Core.registerVehicles(def)
    if type(def) ~= "table" then
        warn("registerVehicles needs a definition")
        return
    end

    local rooms = {}
    if type(def.rooms) == "table" then
        for _, roomId in ipairs(def.rooms) do
            table.insert(rooms, roomId)
        end
    end
    if def.room then
        table.insert(rooms, def.room)
    end
    if #rooms == 0 then
        warn("a binding from " .. tostring(def.source or def.id or "somewhere") .. " names no rooms")
        return
    end

    local id = def.id
    if type(id) ~= "string" then
        anonymous = anonymous + 1
        id = (def.source or "unknown") .. "#" .. anonymous
    end

    Core.bindings[id] = {
        id = id,
        rooms = rooms,
        -- Which register* call made this, and the only thing that decides who
        -- a `match` predicate is shown. It cannot be inferred from the lists:
        -- a binding that is nothing but a matcher names neither scripts nor
        -- items, and that is a legitimate shape -- phun.van is one. Before
        -- this field, roomsForVehicle ran EVERY matcher, so an object
        -- predicate written to read a sprite was handed a BaseVehicle.
        kind = def.kind == "object" and "object" or "vehicle",
        scripts = def.scripts or {},
        -- Moveable item types, for a holder that is a world object rather than
        -- a vehicle. Same table and same union, because the specificity order
        -- is global: a tent room and a van room never compete for a slot, but
        -- they are sorted against each other all the same.
        items = def.items or {},
        -- Only ever ADDS to the script list. It beats maintaining every
        -- StepVan livery in the game, at the cost of claiming modded ones
        -- sight unseen. The room's own `requires` used to filter those back
        -- out; it does not exist any more, so a predicate is now the only thing
        -- standing between a modded van and a room, and it should be written
        -- tightly.
        match = def.match,
        source = def.source or "unknown"
    }

    dirty = true
    Core.debugLn("bound " .. #(def.scripts or {}) .. " script(s) and " .. #(def.items or {}) ..
                     " item(s) to " .. table.concat(rooms, ", ") .. " as '" .. id .. "'")
    return Core.bindings[id]
end

--- Bind placed world objects to rooms, by the moveable item they came from.
--
--     Core.registerObjects{
--         id    = "phun.tent",
--         items = {"Base.TentGreen", "Base.TentBlue"},
--         rooms = {"phun.tent.small"},
--     }
--
-- The item type rather than a sprite name, because a sprite name is not the
-- identity: a green tent is thirty-two sprites and every one of them carries
-- `CustomItem = Base.TentGreen` as a tile property. One string a third party
-- can write down against thirty-two they would have to look up, and it is the
-- string vanilla's own pickup path keys on.
--
-- Everything else is registerVehicles: the same table, the same union across
-- bindings, the same optional `match` that only ever adds. A predicate here is
-- handed the OBJECT, so it can read whatever it likes off the sprite.
function Core.registerObjects(def)
    if type(def) ~= "table" then
        warn("registerObjects needs a definition")
        return
    end
    return Core.registerVehicles({
        kind = "object",
        id = def.id,
        rooms = def.rooms,
        room = def.room,
        items = def.items or {},
        scripts = {},
        match = def.match,
        source = def.source or "unknown"
    })
end

--- Register the shipped blueprint for a room.
--
-- OPTIONAL, and nothing writes one by default. Blueprints are captured in
-- game, per slot, on first lease, and PhunInteriors.author no longer emits
-- this call -- which is what lets a map author decorate the stamps of a room
-- differently and have each restored to what it actually was.
--
-- It is kept because a room-level blueprint is still the only way to make
-- every server restore a room identically, and because it is the one answer
-- available to a slot that missed its capture window. Manifest.forSlot puts it
-- BELOW a slot's own capture and above borrowing from a sibling.
--
-- THE SHAPE, in full:
--
--     Core.registerBlueprint("phun.van.roofed", {
--         version = 2,
--
--         -- Every distinct sprite name in the room, once. 1 based, and the
--         -- order is arbitrary: it is assigned as sprites are first met
--         -- during the scan, so read nothing into it.
--         palette = {
--             "walls_interior_house_01_12",   -- 1
--             "lighting_indoor_01_1",         -- 2
--             "furniture_shelving_01_4"       -- 3
--         },
--
--         -- "dx,dy,dz" RELATIVE to a slot origin, mapping to the palette
--         -- indices standing on that square. Relative is what lets one
--         -- blueprint be applied to every stamp of the room.
--         squares = {
--             ["0,0,0"] = {1, 2},   -- north-west corner: a wall and a switch
--             ["0,1,0"] = {1},
--             ["1,1,0"] = {3}
--         }
--     })
--
-- ONE BLUEPRINT PER ROOM, because that is all this call can be: it is the
-- author's statement of what the room is meant to look like, and it applies to
-- every stamp of it. Runtime capture is per SLOT and beats it, so shipping one
-- sets a floor rather than a ceiling -- a slot restores to its own decor if it
-- captured, and to this if it never did.
--
-- That order is the reverse of what it used to be, and the reversal is the
-- point. Shipped used to win, which meant a per-slot capture could never mean
-- anything and every stamp of a room was flattened to one decor. It also made
-- this file load bearing, with a silent trap attached: repaint a room in the
-- editor, forget to re-export, and the first scrub quietly undid the repaint.
--
-- Three things the shape says which are easy to miss:
--
--   * A square with nothing on it has no key at all. Absent means empty, and
--     a scrub reads it as "clear this square", not "leave it alone".
--   * The floor is never in here. Manifest.isStructural excludes it by
--     identity against square:getFloor(), because a scrub keeps the floor
--     rather than rebuilding it -- and a rebuilt one would stack.
--   * Neither is anything loose. An IsoWorldInventoryObject on the ground is
--     contents, and had it got in, every scrub would faithfully put the
--     previous tenant's nails back.
--
-- The z in a key runs 0 and 1, because a capture covers the room and the
-- level above it.
--
-- Tests/lua/author_spec.lua builds one of these end to end against a stubbed
-- world, if you would rather watch it happen than read about it.
function Core.registerBlueprint(id, def)
    if type(id) ~= "string" or not def or not def.squares then
        warn("registerBlueprint needs a room id and a squares table")
        return
    end

    local count = 0
    for _ in pairs(def.squares) do
        count = count + 1
    end

    Core.blueprints[id] = {
        version = def.version or 2,
        palette = def.palette or {},
        squares = def.squares
    }

    Core.debugLn("registered a shipped blueprint for " .. id .. " (" .. count .. " squares)")
    return Core.blueprints[id]
end

--- A room's shipped blueprint, in the shape Manifest.spritesAt expects.
--
-- Already in that shape, so this is a lookup rather than a view. It stays a
-- function because the stored form is free to change again and everything
-- downstream reads it through here.
function Core.roomBlueprint(id)
    return Core.blueprints[id]
end

--- Let admins add scripts to an existing binding without any code.
-- Sandbox option is a comma separated list of script names.
function Core.applySandboxScriptOverrides()
    for bindingId, binding in pairs(Core.bindings) do
        local optionName = "Scripts_" .. string.gsub(bindingId, "%.", "_")
        local raw = Core.getOption(optionName, "")
        if raw and raw ~= "" then
            for entry in string.gmatch(raw, "([^,]+)") do
                local script = entry:match("^%s*(.-)%s*$")
                if script ~= "" then
                    table.insert(binding.scripts, script)
                    Core.debugLn("sandbox bound '" .. script .. "' to " .. bindingId)
                    dirty = true
                end
            end
        end
    end
end

--- Every room this vehicle may lease, best first.
--
-- Script lookup first because it is a hash hit; matchers only run as well as
-- it, not instead of it, because a matcher only ever ADDS. The union is what
-- lets a map pack offer its rooms to a vehicle somebody else's binding already
-- covers, without either of them having to know the other exists.
--
-- Ordering is the allocation order and is explained in rebuild(): specificity,
-- then the author's priority, then the id.
function Core.roomsForVehicle(vehicle)
    if not vehicle or not vehicle.getScript then
        return {}
    end
    local script = vehicle:getScript()
    if not script then
        return {}
    end
    indexed()

    local wanted = {}
    local function take(binding)
        for _, roomId in ipairs(binding.rooms) do
            if Core.rooms[roomId] then
                wanted[roomId] = true
            end
        end
    end

    local full = string.lower(tostring(script:getFullName()))
    for bindingId in pairs(Core.scriptLookup[full] or {}) do
        local binding = Core.bindings[bindingId]
        if binding then
            take(binding)
        end
    end

    for _, binding in pairs(Core.bindings) do
        if binding.match and binding.kind ~= "object" then
            local ok, matched = pcall(binding.match, vehicle)
            if ok and matched then
                take(binding)
            end
        end
    end

    local out = {}
    for roomId in pairs(wanted) do
        table.insert(out, roomId)
    end
    local rank = Core.roomRank or {}
    table.sort(out, function(a, b)
        return (rank[a] or 0) < (rank[b] or 0)
    end)
    return out
end

--- Does this vehicle have interiors at all?
--
-- The client's whole interest in the registry: whether to offer the radial
-- slice, and whether to track the vehicle's position. Cheaper than the full
-- resolution only in that it stops at the first hit.
function Core.vehicleHasRooms(vehicle)
    return #Core.roomsForVehicle(vehicle) > 0
end

--- Which rooms a placed world object may lease.
--
-- The same walk as roomsForVehicle against the other lookup. Keyed on the
-- moveable item the object was placed from, which is a tile property and so
-- is true of every sprite of a multi-tile object -- any corner of a tent gives
-- the same answer.
function Core.roomsForObject(object)
    local item = Core.moveableItemOf and Core.moveableItemOf(object)
    indexed()

    local wanted = {}
    local function take(binding)
        for _, roomId in ipairs(binding.rooms) do
            if Core.rooms[roomId] then
                wanted[roomId] = true
            end
        end
    end

    if item then
        for bindingId in pairs(Core.itemLookup[string.lower(item)] or {}) do
            local binding = Core.bindings[bindingId]
            if binding then
                take(binding)
            end
        end
    end

    -- A matcher on an object binding is handed the object, not a vehicle. Only
    -- bindings that name items at all are asked, so a vehicle matcher is never
    -- shown an IsoObject it would have to guard against.
    for _, binding in pairs(Core.bindings) do
        if binding.match and binding.kind == "object" then
            local ok, matched = pcall(binding.match, object)
            if ok and matched then
                take(binding)
            end
        end
    end

    local out = {}
    for roomId in pairs(wanted) do
        table.insert(out, roomId)
    end
    local rank = Core.roomRank or {}
    table.sort(out, function(a, b)
        return (rank[a] or 0) < (rank[b] or 0)
    end)
    return out
end

function Core.objectHasRooms(object)
    return #Core.roomsForObject(object) > 0
end

--- Which rooms this holder may lease, whatever kind of holder it is.
--
-- Duck typed rather than flagged, because the caller already has the thing
-- itself and a flag would be a second source of truth for a question the
-- object answers. Slots.acquire is the only caller that has to be kind
-- agnostic; the client menus each know what they are looking at.
function Core.roomsForHolder(holder)
    if not holder then
        return {}
    end
    if Core.holderKindOf(holder) == "vehicle" then
        return Core.roomsForVehicle(holder)
    end
    return Core.roomsForObject(holder)
end

--- Which rooms a vehicle would be entitled to if any of them were registered.
--
-- Same walk as roomsForVehicle, minus the "is it registered" filter, so the
-- difference between the two is exactly the set of rooms somebody named and
-- nobody shipped. Slots.acquire says that at the point of refusal, where the
-- answer is always current -- see unresolvedFor.
function Core.roomsNamedFor(vehicle)
    if not vehicle or not vehicle.getScript then
        return {}
    end
    local script = vehicle:getScript()
    if not script then
        return {}
    end
    indexed()

    local named = {}
    local function take(binding)
        for _, roomId in ipairs(binding.rooms) do
            named[roomId] = true
        end
    end

    local full = string.lower(tostring(script:getFullName()))
    for bindingId in pairs(Core.scriptLookup[full] or {}) do
        if Core.bindings[bindingId] then
            take(Core.bindings[bindingId])
        end
    end
    for _, binding in pairs(Core.bindings) do
        if binding.match and binding.kind ~= "object" then
            local ok, matched = pcall(binding.match, vehicle)
            if ok and matched then
                take(binding)
            end
        end
    end

    local out = {}
    for roomId in pairs(named) do
        table.insert(out, roomId)
    end
    table.sort(out)
    return out
end

--- Is this vehicle moving?
--
-- isStopped() rather than a speed threshold of our own. A stationary vehicle
-- under tow reports a non-zero getCurrentSpeedKmHour -- confirmed in game: a
-- parked towed van refused entry from outside while telling the player it was
-- moving. The coupling never quite settles, so any epsilon we pick is a guess
-- about physics jitter.
--
-- isStopped is the engine's own answer and it is what vanilla gates vehicle
-- interaction on, in ISExitVehicle:isValid and ISVehicleMenu.lua:185. If it is
-- good enough to decide whether you may climb out, it is good enough here.
--- Is this vehicle still a thing we can ask questions of?
--
-- A Lua handle outlives the vehicle. The chunk unloads -- which is exactly
-- what happens the moment a tenant is teleported across the map -- and the
-- handle stays non-nil while the engine side is torn down. isStopped() is
-- `getController().isGasPedalPressed()` internally, so calling it then is a
-- null dereference in Java, surfacing as "Exception thrown" with no useful
-- Lua frame.
--
-- Vanilla never trips this because vanilla only calls isStopped on a vehicle
-- the player is standing next to. We hold references across a teleport, so we
-- have to check.
function Core.vehicleIsLive(vehicle)
    if not vehicle then
        return false
    end
    if vehicle:isRemovedFromWorld() then
        return false
    end
    return vehicle:getController() ~= nil
end

function Core.vehicleIsMoving(vehicle)
    -- Not merely a safe default: an unloaded vehicle *cannot* be moving,
    -- because unloaded means nobody is within the load radius, which means
    -- nobody is driving it. That is the same load rule the stored exit
    -- position depends on. A destroyed one is not moving either.
    if not Core.vehicleIsLive(vehicle) then
        return false
    end
    return not vehicle:isStopped()
end

--- Is this player actually the one driving this vehicle?
--
-- Not just isDriver. Sitting in seat 0 of something under tow is not driving
-- it -- the vehicle in front is -- which is exactly why vanilla has a separate
-- getDriverRegardlessOfTow. Being told you cannot leave the wheel of a van
-- somebody else is towing is the kind of rule that reads as a bug.
function Core.isAtTheWheel(vehicle, player)
    if not vehicle or not player then
        return false
    end
    return vehicle:isDriver(player) and vehicle:getVehicleTowedBy() == nil
end


--- Could this player be put into this seat from outside the vehicle?
--
-- Three facts, and the third is the one that bites. A seat may not be fitted,
-- it may be taken, and it may have no door of its own.
--
-- A script says where a character stands to use a seat with a `position
-- outside` block, and an EMPTY one DELETES the position it inherited from a
-- template: VehicleScript.LoadPosition removes the entry and returns null for
-- a block with no values in it. That is how an author says "this seat is not
-- reachable from the ground" -- vanilla's own VanSeats rear seats do it, and
-- so does the Rolling Refuge RV, which empties five of its six. You board by
-- the one door and switch seats inside.
--
-- Handing such a seat to ISEnterVehicle is a hard error rather than a quiet
-- failure. Its start() does getPassengerPosition(seat, "outside"):getOffset()
-- with no nil check at all (ISEnterVehicle.lua:41-43), and vanilla's own
-- distanceToPassengerPosition is written the same way. So a seat has to pass
-- this before anybody is handed it, and isEnterBlocked is the exact test
-- vanilla's own menu gates on, for this exact reason: see the comment above
-- ISVehicleMenu.getBestSwitchSeatEnter.
--
-- It is more than the nil check, and the rest is worth having. isExitBlocked,
-- which isEnterBlocked is a one line alias for, also runs lineClearCollide
-- between the seat's inside and outside positions, so a door up against a wall
-- is refused too. PolygonalMap2.instance is built in a static initialiser and
-- is therefore never nil, and the only client-only branch in there is gated on
-- GameClient.client, so this is safe to ask on a dedicated server -- which is
-- what lets it be one implementation rather than two that can disagree.
function Core.seatIsEnterable(vehicle, seat, character)
    if not vehicle or not seat or seat < 0 then
        return false
    end
    if not vehicle:isSeatInstalled(seat) or vehicle:isSeatOccupied(seat) then
        return false
    end
    return not vehicle:isEnterBlocked(character, seat)
end

--- Can this player move from where they are into the interior right now?
-- Returns true, or false plus a translation key.
--
-- Shared, and there is exactly one copy on purpose. The server enforces this
-- in Transit.canEnter; the client checks the same function in beginEnter so a
-- refusal is instant rather than arriving after a fifteen second action. Two
-- copies of a rule like this drift, which is the mistake the reference mod
-- made with its whole SP path.
--
-- Moving between a seat and the interior is an internal move, and allowed --
-- the mirror of leaving the interior into a free seat while under way. The two
-- things that are not allowed are catching a vehicle you are not aboard, and
-- walking away from the wheel of one you are driving.
function Core.vehicleMotionAllows(vehicle, player)
    if not Core.vehicleIsMoving(vehicle) then
        return true
    end
    if player:getVehicle() ~= vehicle then
        -- The speed is logged because this is the refusal that went wrong
        -- once already: a parked towed van reported enough movement to trip a
        -- fixed threshold, and the only symptom was a refusal that made no
        -- sense to the player standing next to a stationary vehicle.
        Core.debugLn(string.format("refused boarding: %s is not stopped (%.2f km/h)", tostring(vehicle:getScriptName()),
            vehicle:getCurrentSpeedKmHour()))
        return false, "IGUI_PhunInteriors_VehicleMovingBoard"
    end
    if Core.isAtTheWheel(vehicle, player) then
        return false, "IGUI_PhunInteriors_DrivingCannotEnter"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- THERE IS NO `requires`, AND THERE IS NO Core.roomAllows.
--
-- A room used to be able to state demands on the vehicle leasing it --
-- `trunk`, whether there was cargo space to put the room in, and `battery`,
-- whether there was charge -- tested per candidate during allocation by
-- Core.roomAllows. Both are gone, along with the function, the two refusal
-- messages and the ordering they complicated.
--
-- Removed because nothing used them. Across the whole shipped map not one room
-- declared either, and the only job `requires` ever did beyond documentation
-- was refuse the `StepVan*Smashed*` wrecks that the `phun.van` MATCHER
-- over-claimed -- and the matcher went when every vehicle was listed
-- explicitly. A feature whose last real user was deleted is not a safety net,
-- it is a thing that still has to be understood.
--
-- And it was actively dangerous, because it was a VEHICLE vocabulary asked
-- during allocation, which is holder agnostic. Put "have you a trunk" to a
-- tent and it cannot answer, and answering "no" is wrong in a way that is hard
-- to see: the demand is INAPPLICABLE, not unmet. That is not hypothetical --
-- every shipped room once declared `requires = {trunk = true}`, so there was
-- no room on the map a tent could be given, and the refusal arrived as "this
-- vehicle has no interior" about a tent. It was fixed by confining the
-- vocabulary to vehicles; deleting it removes the class of bug instead.
--
-- WHICH HOLDER MAY LEASE WHICH ROOM IS THE BINDING'S ANSWER, and always was.
-- Core.roomsForVehicle walks only bindings made by registerVehicles and
-- Core.roomsForObject only those made by registerObjects, so by the time
-- allocation runs, a candidate has already been named by a binding of this
-- holder's own kind. That is why nothing replaces this: the question it
-- answered was already answered upstream.
--
-- If a room ever needs to refuse a holder on a fact about the holder, the
-- lesson from this one is to put it on the BINDING, which knows what kind of
-- thing it is naming, rather than on the room, which does not.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The reverse indexes.
--
-- Both are derived, both are rebuilt from scratch, and the rebuild is deferred
-- to the first read after a registration. Nothing here is authoritative; the
-- register* calls are.
-- ---------------------------------------------------------------------------

-- Slot lookups are bucketed by this many squares. Rooms are far smaller than a
-- bucket, so a point lands in one bucket and its candidate list is short.
local BUCKET = 64

local function bucketKey(x, y)
    return math.floor(x / BUCKET) .. "," .. math.floor(y / BUCKET)
end

local function rebuild()
    -- Every script -> binding edge, and every binding -> room edge. Both are
    -- unioned across bindings: a script named by two of them draws from both
    -- their room lists, which is how a map pack offers rooms to a vehicle
    -- somebody else's binding already covers.
    local scripts = {}
    for bindingId, binding in pairs(Core.bindings) do
        for _, script in ipairs(binding.scripts or {}) do
            local key = string.lower(script)
            scripts[key] = scripts[key] or {}
            scripts[key][bindingId] = true
        end
    end

    -- The same edge for a holder that is a world object. Kept in its own
    -- lookup rather than folded in with the scripts, because a moveable item
    -- type and a vehicle script name are different namespaces and nothing good
    -- comes of a collision between them being silent.
    local items = {}
    for bindingId, binding in pairs(Core.bindings) do
        for _, item in ipairs(binding.items or {}) do
            local key = string.lower(item)
            items[key] = items[key] or {}
            items[key][bindingId] = true
        end
    end

    -- How many distinct SCRIPTS can reach a room is its specificity, and
    -- allocation drains the most specialised room first.
    --
    -- Without that ordering the pool starves in a way that reads as a bug. Say
    -- room A is reachable by vans and pickups and room B only by vans. First
    -- fit hands vans rooms out of A, A fills, and pickups -- which have
    -- nowhere else to go -- are refused while B sits empty. General purpose
    -- capacity has to be kept for the vehicles that have no alternative, so a
    -- vehicle with a choice takes the narrowest room it is entitled to.
    --
    -- Scripts, not bindings. Counting bindings looks equivalent and is not: a
    -- single binding naming two scripts makes its rooms reachable by two
    -- vehicles, which is exactly the generality this is measuring, and
    -- counting the binding as one hides it. Two rooms then tie, fall through
    -- to the id tiebreak, and the starvation above is back.
    --
    -- A matcher covers an unbounded number of scripts, so a room reachable
    -- through one is maximally general and is weighted to sort last. That is
    -- not a fudge around the unbounded count -- it is the right answer.
    -- Anything at all might claim that room, so it is the worst possible place
    -- to put a vehicle that had somewhere else to go.
    local MATCHER_WEIGHT = 1000000
    local reach, unresolved = {}, {}
    for bindingId, binding in pairs(Core.bindings) do
        for _, roomId in ipairs(binding.rooms) do
            if Core.rooms[roomId] then
                reach[roomId] = reach[roomId] or {scripts = {}, items = {}, matchers = 0}
                for _, script in ipairs(binding.scripts or {}) do
                    -- Keyed lowercase so two spellings of one script count
                    -- once, valued as written so anything showing the list to
                    -- a human shows "Base.StepVan" rather than "base.stepvan".
                    reach[roomId].scripts[string.lower(script)] = script
                end
                -- Counted alongside the scripts, because specificity measures
                -- how many distinct things can reach a room and a moveable
                -- item type is one of those things. Listed apart, because
                -- "which vehicles can get in here" and "which objects can" are
                -- different questions to anybody reading the answer.
                for _, item in ipairs(binding.items or {}) do
                    reach[roomId].items[string.lower(item)] = item
                end
                if binding.match then
                    reach[roomId].matchers = reach[roomId].matchers + 1
                end
            else
                -- A binding naming a room nobody registered. Not an error and
                -- not fatal -- it contributes nothing -- but it is the
                -- difference between "this vehicle was never given rooms" and
                -- "the mod that owns its rooms is not installed", which is
                -- worth being able to say when somebody asks why a van has no
                -- interior.
                unresolved[bindingId] = unresolved[bindingId] or {}
                table.insert(unresolved[bindingId], roomId)
            end
        end
    end
    for _, list in pairs(unresolved) do
        table.sort(list)
    end

    -- The counts allocation orders by, and the names themselves.
    --
    -- Only the count used to be kept, because only the count is needed to sort
    -- rooms. The names are the answer to "what can actually get into this
    -- room", which is the first thing anybody asks of a room they did not
    -- write, and deriving it again at the point of asking would mean a second
    -- walk over every binding that could disagree with this one.
    local served, scriptsFor = {}, {}
    for roomId, r in pairs(reach) do
        local n = r.matchers * MATCHER_WEIGHT
        local names = {}
        for _, script in pairs(r.scripts) do
            n = n + 1
            table.insert(names, script)
        end
        local itemNames = {}
        for _, item in pairs(r.items or {}) do
            n = n + 1
            table.insert(itemNames, item)
        end
        table.sort(itemNames, function(a, b)
            return string.lower(a) < string.lower(b)
        end)
        -- Case insensitively, because the spelling kept is whichever binding
        -- the hash order reached last and a plain sort would file "Base.Van"
        -- and "base.stepvan" at opposite ends of the list.
        table.sort(names, function(a, b)
            return string.lower(a) < string.lower(b)
        end)
        served[roomId] = n
        scriptsFor[roomId] = {
            scripts = names,
            items = itemNames,
            matchers = r.matchers
        }
    end

    -- The allocation order, precomputed as a rank so the per-entry sort is a
    -- couple of integer compares and needs no access to this closure.
    local order = {}
    for roomId in pairs(Core.rooms) do
        table.insert(order, roomId)
    end
    table.sort(order, function(a, b)
        -- Specificity first, because that one is correctness: it is what stops
        -- a general purpose room starving the vehicles that have nowhere else
        -- to go.
        local sa, sb = served[a] or 0, served[b] or 0
        if sa ~= sb then
            return sa < sb
        end
        -- Then the author's stated preference. Equally specialised rooms are
        -- not equally good -- a room with no power is a worse room than one
        -- with a working light, and handing those out first because their id
        -- sorts earlier is a bug the player experiences rather than a detail.
        local pa = Core.rooms[a].priority or 0
        local pb = Core.rooms[b].priority or 0
        if pa ~= pb then
            return pa < pb
        end
        -- Ties broken by id so allocation does not depend on hash order, which
        -- would make the same save hand out different rooms on different runs.
        return a < b
    end)
    local rank = {}
    for i, roomId in ipairs(order) do
        rank[roomId] = i
    end

    local spatial = {}
    for roomId, room in pairs(Core.rooms) do
        for _, index in ipairs(room.indices) do
            local b = Core.slotBounds(room, index)
            if b then
                local entry = {
                    id = roomId,
                    index = index,
                    bounds = b
                }
                for bx = math.floor(b.x1 / BUCKET), math.floor(b.x2 / BUCKET) do
                    for by = math.floor(b.y1 / BUCKET), math.floor(b.y2 / BUCKET) do
                        local key = bx .. "," .. by
                        spatial[key] = spatial[key] or {}
                        table.insert(spatial[key], entry)
                    end
                end
            end
        end
    end

    Core.scriptLookup = scripts
    Core.itemLookup = items
    Core.roomsServing = served
    Core.roomScripts = scriptsFor
    Core.roomRank = rank
    Core.unresolvedRooms = unresolved
    Core.slotBuckets = spatial
    dirty = false
end

function indexed()
    if dirty then
        rebuild()
    end
end

--- How many distinct scripts can reach this room -- its specificity.
--
-- A room reachable through a `match` predicate carries a large weight, because
-- an unbounded number of scripts can claim it and it is therefore the most
-- general room there is.
--
-- A function rather than the raw table, because the table is rebuilt lazily
-- and reading it directly after a registration hands back the previous
-- answer. That is a trap nobody would notice until allocation ordered itself
-- against stale numbers.
function Core.servingCount(roomId)
    indexed()
    return (Core.roomsServing or {})[roomId] or 0
end

--- Which vehicle scripts can reach this room, and how many matchers can too.
--
-- The reverse of roomsForVehicle, and the only question the admin room list
-- asks of the registry: a room designer looking at a list of rooms wants to
-- know what would have to be parked outside to get into each one.
--
-- The matcher count is returned separately rather than folded in, because a
-- matcher is an unbounded set and a list that quietly rendered it as nothing
-- would say "no vehicle can reach this room" about a room anything can reach.
function Core.scriptsForRoom(roomId)
    indexed()
    local entry = (Core.roomScripts or {})[roomId]
    if not entry then
        return {}, 0
    end
    return entry.scripts, entry.matchers
end

--- The slots whose bounds could contain this point. Short list, no arithmetic.
function Core.slotCandidates(x, y)
    indexed()
    return Core.slotBuckets[bucketKey(x, y)]
end

--- Rooms this vehicle was bound to that nobody registered.
--
-- Deliberately asked for at the point of failure rather than reported at boot.
-- A third party is free to register from any vanilla hook it likes, which may
-- well be later than our own registration events, so anything logged at boot
-- is a guess that can be wrong in the direction that matters -- warning about
-- a room that turns up a moment later. Asked when a vehicle is actually
-- refused a room, the answer is always current.
--
-- Takes the vehicle rather than a binding id because a vehicle can be covered
-- by several bindings, and "which of the rooms I was promised are missing" is
-- the question somebody actually has.
function Core.unresolvedFor(vehicle)
    indexed()
    local missing = {}
    for _, roomId in ipairs(Core.roomsNamedFor(vehicle)) do
        if not Core.rooms[roomId] then
            table.insert(missing, roomId)
        end
    end
    if #missing == 0 then
        return nil
    end
    return missing
end

--- What the registry ended up holding. Counts only, so it is always true.
function Core.describeRegistry()
    indexed()
    local rooms, slots = 0, 0
    for _, room in pairs(Core.rooms) do
        rooms = rooms + 1
        slots = slots + #room.indices
    end
    local bindings = 0
    for _ in pairs(Core.bindings) do
        bindings = bindings + 1
    end
    return string.format("%d room(s), %d slot(s), %d binding(s)", rooms, slots, bindings)
end

-- Slot geometry. The leash, the exit test and the scrub all read from here, so
-- there is exactly one definition of where a slot actually is.
--
-- A slot's position is now looked up rather than computed, so an index that no
-- longer exists yields nil rather than a plausible looking box somewhere in
-- the middle of nowhere. That happens when a set is re-registered smaller than
-- a live lease; Slots.acquire is what notices and lets the lease go.
-- ---------------------------------------------------------------------------

function Core.slotOrigin(room, index)
    return room and room.slots and room.slots[index] or nil
end

function Core.slotBounds(room, index)
    local o = Core.slotOrigin(room, index)
    if not o then
        return nil
    end
    return {
        x1 = o.x,
        y1 = o.y,
        x2 = o.x + room.size.w - 1,
        y2 = o.y + room.size.h - 1,
        z = o.z
    }
end

--- The part of a slot a tenant may stand in: the footprint less its last row
--- and column.
--
-- `size` is a FOOTPRINT, and PZ draws a room's walls unevenly: the north and
-- west walls sit on the room's own edge squares, the south and east walls on
-- the edge of the squares BEYOND the floor. So the footprint's last row and
-- column are on the far side of their walls. The scrub, the capture scan, the
-- destroy guards and the fire sweep all need those squares -- the south and
-- east wall objects live on them -- but a player standing on one has already
-- walked out of the room.
--
-- The leash tested the footprint until the ambulance bays gained a south
-- doorway, and a tenant walking out of it was not ejected until the square
-- after: the one just past the wall still counted as inside. A north exit
-- never showed it, because the north wall is on the floor's own row.
function Core.slotFloor(room, index)
    local b = Core.slotBounds(room, index)
    if not b then
        return nil
    end
    b.x2 = math.max(b.x1, b.x2 - 1)
    b.y2 = math.max(b.y1, b.y2 - 1)
    return b
end

function Core.slotSpawn(room, index)
    local o = Core.slotOrigin(room, index)
    if not o then
        return nil
    end
    return {
        x = o.x + room.spawn.x,
        y = o.y + room.spawn.y,
        z = o.z
    }
end

function Core.inBounds(bounds, x, y, z)
    if not bounds then
        return false
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    return z == bounds.z and x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2
end

--- Where the generator lives in this slot, or nil if the room has none.
--
-- The offset is the room's `generator`, captured by the authoring tool and
-- emitted into its blueprint file. The z is relative, so a room may put its
-- generator on the level above the floor -- which is why every sweep over a
-- slot covers bounds.z to bounds.z + 1 -- but the shipped map does not: it
-- puts it 17 squares south on open ground, and assuming otherwise is what
-- built a generator on fifty roofs.
function Core.slotPower(room, index)
    local p = room and room.generator
    if not p then
        -- No generator, by design. Every caller has to read this as "this room
        -- has no power" rather than "look somewhere sensible instead", which
        -- is why there is no default here and none in registerRoom either.
        return nil
    end
    local o = Core.slotOrigin(room, index)
    if not o then
        return nil
    end
    return {
        x = o.x + (p.x or p[1] or 0),
        y = o.y + (p.y or p[2] or 0),
        z = o.z + (p.z or p[3] or 0)
    }
end

--- Which edge of the box this point is beyond, or nil if it is inside.
--
-- Fixed order rather than pairs, because a player standing diagonally off a
-- corner is over two edges at once and `pairs` would pick between them
-- differently from one run to the next. The overshoots are compared with a
-- strict >, so the first edge in this list wins a tie; which one that is
-- matters far less than it being the same one every time.
local EDGES = {"north", "south", "west", "east"}

function Core.edgeCrossed(bounds, x, y)
    if not bounds then
        return nil
    end
    x, y = math.floor(x), math.floor(y)
    local over = {
        north = bounds.y1 - y,
        south = y - bounds.y2,
        west = bounds.x1 - x,
        east = x - bounds.x2
    }
    local edge, by = nil, 0
    for _, name in ipairs(EDGES) do
        if over[name] > by then
            edge, by = name, over[name]
        end
    end
    return edge
end

return Core
