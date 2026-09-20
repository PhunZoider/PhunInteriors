if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = require "PhunInteriors/manifest"
local Author = {}
Core.modules.author = Author

-- ---------------------------------------------------------------------------
-- Authoring a room.
--
-- What a map author has to get right is nothing but coordinates -- the room
-- origin, its size, the spawn tile, the generator offset -- and every one of
-- them fails silently when it is wrong. A bad origin means the room never
-- loads; a spawn tile inside a wall strands a tenant. So none of them should
-- be typed.
--
-- This builds a room from where the author is standing and emits the lua that
-- registers it. The emitted file is shipped in the mod and loads itself; there
-- is no runtime file reading anywhere in this design.
--
-- It no longer emits blueprints. Those are captured in game, per slot, on
-- first lease, which is what lets an author decorate the stamps differently
-- and have each one restored to what it actually was. So what this tool
-- writes is the CONTRACT -- shape, spawn, exits, generator, locations, and
-- which vehicles fit -- and all of that is now hand-writable if you would
-- rather. Sweeping is kept as a check that a room reads cleanly before you
-- ship it, not as a prerequisite for emitting.
--
-- Console driven on purpose. Every input here is "where am I standing" plus a
-- couple of numbers, which a console call expresses fine, and a panel later is
-- then a view over these same functions rather than a rewrite. That is the
-- same argument that kept Admin.run a single action dispatcher.
-- ---------------------------------------------------------------------------

-- One session at a time. Authoring is a single admin sitting in a map they are
-- building; there is no case for concurrent sessions and pretending otherwise
-- would mean keying all of this by player for no gain.
local session = nil

local function need()
    if not session then
        return nil, "no authoring session; start one with author('begin', {id = 'yourmod.van'})"
    end
    return session
end

local function playerPosition()
    local players = Core.tools.onlinePlayers()
    if not players or players:size() == 0 then
        return nil
    end
    local player = players:get(0)
    if not player then
        return nil
    end
    return math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

function Author.begin(args)
    local id = args and args.id
    if not id or not id:find("%.") then
        return {"begin needs a namespaced id, eg author('begin', {id = 'yourmod.van'})"}
    end

    session = {
        id = id,
        label = args.label or id,
        corners = {},
        front = nil,
        cab = false,
        spawn = nil,
        power = nil,
        -- Absolute origin of every room, in index order. Room 0 is seeded by
        -- marking the corners; the rest come from `at`, or from `strip` when
        -- the layout really is a uniform run.
        slots = {},
        scripts = {},
        match = args.match,
        -- nil or true takes a reservoir; only an explicit false opts out
        reservoir = args.reservoir,
        blueprints = {}
    }

    return {"authoring " .. id,
            "stand in one corner of the FIRST room and call author('corner'), then the opposite corner",
            "then: spawn, exit, power",
            "then place the rooms: author('at') in each one, or author('strip') for a uniform run",
            "then: scripts, sweep, emit"}
end

function Author.cancel()
    session = nil
    return {"authoring session discarded"}
end

-- ---------------------------------------------------------------------------
-- Geometry, read from where the author is standing
-- ---------------------------------------------------------------------------

function Author.corner()
    local s, err = need()
    if not s then
        return {err}
    end

    local x, y, z = playerPosition()
    if not x then
        return {"could not find you"}
    end

    if #s.corners >= 2 then
        s.corners = {}
    end
    table.insert(s.corners, {
        x = x,
        y = y,
        z = z
    })

    if #s.corners < 2 then
        return {string.format("corner 1 at %d,%d,%d -- now stand in the opposite corner", x, y, z)}
    end

    local a, b = s.corners[1], s.corners[2]
    -- The author stands in corners in whatever order suits them, so normalise
    -- rather than requiring north-west first.
    s.origin = {
        x = math.min(a.x, b.x),
        y = math.min(a.y, b.y),
        z = math.min(a.z, b.z)
    }
    s.size = {
        w = math.abs(a.x - b.x) + 1,
        h = math.abs(a.y - b.y) + 1
    }

    -- Marking the corners places room 0 as well as sizing it. Re-marking moves
    -- room 0 rather than adding one, which is what an author correcting a
    -- misplaced corner means; the rooms placed after it are left alone.
    s.slots[1] = {
        x = s.origin.x,
        y = s.origin.y,
        z = s.origin.z
    }

    return {string.format("room is %dx%d with its origin at %d,%d,%d", s.size.w, s.size.h, s.origin.x, s.origin.y,
        s.origin.z), "that is room 0; stand in the same corner of each other room and call author('at')"}
end

--- Tiles are recorded relative to the slot origin, which is what the registry
--- wants and what makes one blueprint apply to every slot in the strip.
--- "south (cab)", or "none", for the status line.
local function frontSummary(s)
    local parts = {}
    if s.front then
        table.insert(parts, s.front .. (s.cab and " (cab)" or ""))
    end
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, ", ")
end

local function relative(s)
    local x, y, z = playerPosition()
    if not x then
        return nil, "could not find you"
    end
    if not s.origin then
        return nil, "mark the room corners first"
    end
    return {
        x = x - s.origin.x,
        y = y - s.origin.y,
        z = z - s.origin.z
    }
end

function Author.spawn()
    local s, err = need()
    if not s then
        return {err}
    end
    local at, why = relative(s)
    if not at then
        return {why}
    end
    s.spawn = at
    return {string.format("spawn tile is %d,%d in the room", at.x, at.y)}
end

--- Mark the wall you are standing at as the way into the cab.
--
-- Stand in the doorway -- or anywhere along the wall it is in -- and this
-- works out which EDGE of the footprint that is and records it. Walking out
-- that side of the room then puts the tenant in a seat instead of on the road.
--
-- An edge rather than the square you are standing on, and that is a
-- correction. A cab tile lasted about an hour: a tile in a doorway is a square
-- you walk THROUGH, the leash samples at 4Hz, and a player at a run is quite
-- likely never seen on it -- so the cab door would have worked at a walk and
-- dropped you in the road at a run. The edge is seen either way, because
-- being outside the box is a state you stay in.
--
-- Naming it again removes it, so a wall marked by mistake is undone by
-- standing at it again rather than by restarting.
function Author.cab()
    local s, err = need()
    if not s then
        return {err}
    end
    if not s.size then
        return {"mark the room corners first"}
    end
    local at, why = relative(s)
    if not at then
        return {why}
    end

    -- Nearest edge of the footprint, which for somebody standing in a doorway
    -- is the wall the doorway is in. Distances to all four, smallest wins;
    -- ties break in this order, which only happens in a room small enough for
    -- the answer not to matter.
    local candidates = {{"north", at.y}, {"south", s.size.h - 1 - at.y}, {"west", at.x},
                        {"east", s.size.w - 1 - at.x}}
    local edge, best = nil, nil
    for _, candidate in ipairs(candidates) do
        local distance = math.abs(candidate[2])
        if not best or distance < best then
            edge, best = candidate[1], distance
        end
    end

    -- A cab is always at the FRONT of the thing, so marking a wall as the cab
    -- side is the same act as saying which way the holder points. Setting both
    -- here is not two facts: it is one fact that two fields spell, and they
    -- cannot disagree because nothing else writes either.
    if s.front == edge and s.cab then
        s.front, s.cab = nil, false
        return {string.format("the %s wall is no longer the cab side", edge)}
    end
    s.front, s.cab = edge, true
    return {string.format("the %s wall leads to the cab (you are %d from it)", edge, best)}
end

function Author.power()
    local s, err = need()
    if not s then
        return {err}
    end
    local at, why = relative(s)
    if not at then
        return {why}
    end
    s.power = at
    return {string.format("power square at %d,%d,%d in the room", at.x, at.y, at.z)}
end

--- Place one more room, at the corner the author is standing in.
--
-- The general case, and the reason placement stopped being arithmetic. A map
-- gets laid out to suit the map: strips with different spacing, a room moved
-- to dodge something, a second cell that does not line up with the first. None
-- of that is expressible as origin + pitch * index, and trying to force it is
-- what put two of these rooms on grids 35 tiles apart.
--
-- Standing in the room is also the only check that matters. An origin typed
-- into a file is a guess; an origin read off the author's feet is where the
-- room actually is.
function Author.at()
    local s, err = need()
    if not s then
        return {err}
    end
    if not s.size then
        return {"mark the room corners first -- that sizes the room and places room 0"}
    end

    local x, y, z = playerPosition()
    if not x then
        return {"could not find you"}
    end

    -- Standing in a room already placed replaces it rather than adding a
    -- duplicate, so a misplaced room is corrected by walking back to it.
    for i, slot in ipairs(s.slots) do
        if x >= slot.x and x < slot.x + s.size.w and y >= slot.y and y < slot.y + s.size.h and z == slot.z then
            s.slots[i] = {
                x = x,
                y = y,
                z = z
            }
            return {string.format("moved room %d to %d,%d,%d", i - 1, x, y, z)}
        end
    end

    table.insert(s.slots, {
        x = x,
        y = y,
        z = z
    })
    return {string.format("room %d at %d,%d,%d (%d placed)", #s.slots - 1, x, y, z, #s.slots)}
end

--- Place a uniform run in one call, rather than walking it room by room.
--
-- Kept, because a genuinely uniform strip is still the common case and saying
-- it in three numbers beats thirty calls to `at`. It expands into the same
-- list of positions, so nothing downstream knows the difference.
function Author.strip(args)
    local s, err = need()
    if not s then
        return {err}
    end

    local count = tonumber(args and args.count)
    local pitchX = tonumber(args and args.pitchX) or 0
    local pitchY = tonumber(args and args.pitchY) or 0

    if not count or count < 1 then
        return {"strip needs a count, eg author('strip', {count = 38, pitchX = 60})"}
    end
    if pitchX == 0 and pitchY == 0 then
        return {"strip needs a pitchX or a pitchY -- the spacing between rooms"}
    end
    if not s.size then
        return {"mark the room corners first"}
    end
    if pitchX ~= 0 and pitchX < s.size.w then
        return {string.format("pitchX %d is narrower than the room (%d wide); rooms would overlap", pitchX, s.size.w)}
    end
    if pitchY ~= 0 and pitchY < s.size.h then
        return {string.format("pitchY %d is shorter than the room (%d deep); rooms would overlap", pitchY, s.size.h)}
    end

    -- count has always been the highest index rather than how many rooms, and
    -- slot 0 is the one the corners placed, so a run of `count` expands to
    -- count + 1 positions. Kept that way deliberately: leases in existing
    -- saves are keyed by that numbering.
    s.slots = {}
    for index = 0, count do
        table.insert(s.slots, {
            x = s.origin.x + (pitchX * index),
            y = s.origin.y + (pitchY * index),
            z = s.origin.z
        })
    end

    return {string.format("%d rooms placed, %d apart on %s", #s.slots, pitchX ~= 0 and pitchX or pitchY,
        pitchX ~= 0 and "x" or "y"), "this replaced any rooms placed with author('at')"}
end

--- What the fitted-out room weighs empty.
function Author.baseweight(args)
    local s, err = need()
    if not s then
        return {err}
    end
    s.baseWeight = tonumber(args and args.base) or 0
    return {string.format("an empty room of this set weighs %.1f", s.baseWeight)}
end

--- Which vehicles get this interior.
function Author.scripts(args)
    local s, err = need()
    if not s then
        return {err}
    end

    local raw = args and args.scripts
    if not raw then
        return {"scripts needs a comma separated list, eg author('scripts', {scripts = 'Base.Van, Base.VanSeats'})"}
    end

    s.scripts = {}
    for entry in string.gmatch(raw, "([^,]+)") do
        local script = entry:match("^%s*(.-)%s*$")
        if script ~= "" then
            table.insert(s.scripts, script)
        end
    end

    if args.match then
        s.match = args.match
    end

    return {string.format("%d script(s) bound%s", #s.scripts,
        s.match and (", plus anything starting '" .. s.match .. "'") or "")}
end

-- ---------------------------------------------------------------------------
-- Reading the rooms
-- ---------------------------------------------------------------------------

--- A room definition good enough to scan with, before it is registered.
--
-- Built in the shape registerRoom stores rather than the shape it accepts,
-- because Manifest and Core.slotOrigin read the stored form. The session's
-- slot list is 1-based like every Lua array; slot indices are 0-based because
-- that is what a lease persists.
local function provisional(s)
    local slots, indices = {}, {}
    for i, position in ipairs(s.slots) do
        slots[i - 1] = position
        table.insert(indices, i - 1)
    end

    return {
        id = s.id,
        slots = slots,
        indices = indices,
        count = #indices - 1,
        size = s.size,
        spawn = s.spawn or {
            x = 1,
            y = 1
        },
        front = s.front,
        cab = s.cab,
        reservoir = s.reservoir ~= false,
        -- No default. A session that has not marked a generator describes a
        -- room with none, which is what nil means everywhere else too.
        generator = s.power
    }
end

--- Scan every slot whose chunk happens to be loaded right now.
--
-- Called repeatedly as the author walks the strip. It reports what it still
-- owes rather than failing, because sweeping a 38 room strip is a walk and the
-- author needs to know when they are done.
function Author.sweep()
    local s, err = need()
    if not s then
        return {err}
    end
    if not s.origin or #s.slots == 0 then
        return {"mark the corners and place the rooms first (author('at') or author('strip'))"}
    end

    local room = provisional(s)
    local captured, already, missing = 0, 0, {}

    for _, index in ipairs(room.indices) do
        if s.blueprints[index] then
            already = already + 1
        else
            local blueprint = Manifest.scanSlot(room, index)
            if blueprint then
                s.blueprints[index] = blueprint
                captured = captured + 1
            else
                table.insert(missing, index)
            end
        end
    end

    local lines = {string.format("swept: %d new, %d already had, %d still missing", captured, already, #missing)}

    if #missing > 0 then
        local shown = {}
        for i = 1, math.min(12, #missing) do
            table.insert(shown, tostring(missing[i]))
        end
        table.insert(lines, "walk to slot(s): " .. table.concat(shown, ", ") ..
            (#missing > 12 and (" and " .. (#missing - 12) .. " more") or ""))
        local next_ = room.slots[missing[1]]
        if next_ then
            table.insert(lines, string.format("slot %d starts at %d,%d", missing[1], next_.x, next_.y))
        end
    else
        table.insert(lines, "every slot captured -- ready to emit")
    end

    return lines
end

function Author.status()
    local s, err = need()
    if not s then
        return {err}
    end

    local have = 0
    for _ in pairs(s.blueprints) do
        have = have + 1
    end

    local placed = {}
    for i, slot in ipairs(s.slots) do
        if i <= 6 then
            table.insert(placed, string.format("%d@%d,%d", i - 1, slot.x, slot.y))
        end
    end
    if #s.slots > 6 then
        table.insert(placed, "and " .. (#s.slots - 6) .. " more")
    end

    return {"id: " .. s.id,
            "origin: " .. (s.origin and string.format("%d,%d,%d", s.origin.x, s.origin.y, s.origin.z) or "not set"),
            "size: " .. (s.size and (s.size.w .. "x" .. s.size.h) or "not set"),
            "rooms: " .. (#s.slots > 0 and (#s.slots .. " -- " .. table.concat(placed, ", ")) or "none placed"),
            "spawn: " .. (s.spawn and (s.spawn.x .. "," .. s.spawn.y) or "not set"),
            "front: " .. frontSummary(s),
            "base weight: " .. tostring(s.baseWeight or 0),
            "power: " .. (s.power and string.format("%d,%d,%d", s.power.x, s.power.y, s.power.z) or "default"),
            "scripts: " .. #s.scripts, "blueprints: " .. have .. " of " .. #s.slots}
end

-- ---------------------------------------------------------------------------
-- Emitting
--
-- The output is lua, not json, and that is the whole point of the design: a
-- file dropped in media/lua/server/PhunInteriors/blueprints/ is loaded by the
-- game on boot and registers itself. No file reading at runtime, no parser, no
-- paths to get wrong, and it works identically on a dedicated server from the
-- first tick rather than accumulating as players happen to visit rooms.

--- A lua string literal, escaped. Sprite and script names are plain, but an
--- emitted file that is not valid lua fails at boot with no useful message.
local function quote(text)
    return string.format("%q", tostring(text))
end
-- ---------------------------------------------------------------------------


function Author.emit(args)
    local s, err = need()
    if not s then
        return {err}
    end

    local problems = {}
    if not s.origin or not s.size then
        table.insert(problems, "room corners not marked")
    end
    if #s.slots == 0 then
        table.insert(problems, "no rooms placed -- use author('at') or author('strip')")
    end
    if not s.spawn then
        table.insert(problems, "spawn tile not set")
    end
    -- Deliberately no check for a cab landing. A room without one is the normal
    -- case -- you walk out of it -- and demanding one would make every trailer
    -- room unemittable.
    if #s.scripts == 0 and not s.match then
        table.insert(problems, "no vehicle scripts bound")
    end
    if #problems > 0 then
        local lines = {"cannot emit yet:"}
        for _, problem in ipairs(problems) do
            table.insert(lines, "  " .. problem)
        end
        return lines
    end

    local have = 0
    for _ in pairs(s.blueprints) do
        have = have + 1
    end
    local wanted = #s.slots
    -- No capture is required to emit, because the emitted file no longer
    -- carries one. Blueprints are captured at runtime, per slot, on first
    -- lease -- which is what lets a map author decorate the stamps differently
    -- and have each restored to what it actually was. What this file carries
    -- is the CONTRACT: shape, spawn, exits, generator, and where the room is
    -- stamped.
    --
    -- Sweeping is still worth doing and is still what author('sweep') is for:
    -- it is how you find out, before shipping, that a room does not read
    -- cleanly. It is a check now rather than a prerequisite.
    local safeName = s.id:gsub("[^%w]", "_")
    local path = "PhunInteriors_" .. safeName .. ".lua"
    local file = getFileWriter(path, true, false)
    if not file then
        return {"could not open " .. path .. " for writing"}
    end

    local function line(text)
        file:write((text or "") .. "\r\n")
    end

    line("-- Generated by PhunInteriors.author. Do not hand edit: re-export instead.")
    line("-- Room " .. s.id .. ", stamped at " .. wanted .. " locations.")
    line("-- Drop this in media/lua/server/PhunInteriors/blueprints/ and ship it.")
    line("")
    line("local Core = PhunInteriors")
    line("")
    -- Two handlers, because this file carries both halves: the room belongs in
    -- the room phase and the binding in the vehicle phase. A third party
    -- shipping only rooms writes only the first.
    line("Events[Core.events.OnRegisterRooms].Add(function()")
    line("")
    line("    Core.registerRoom(" .. quote(s.id) .. ", {")
    line("        label = " .. quote(s.label) .. ",")
    line("        source = " .. quote(s.id:match("^([^.]+)") or "authored") .. ",")
    -- Always the explicit keyed list, even for a run that came from `strip`.
    -- The tool cannot tell a strip that happens to be uniform from one that is
    -- uniform on purpose, and a list is right either way; guessing wrong is
    -- how two of these ended up on grids that did not line up. Positions are
    -- also the half of this file a human reviews, and a list is legible in a
    -- way that origin-plus-pitch is not.
    --
    -- Keyed by index rather than merely ordered. A lease persists
    -- {room, index}, so the numbering has to survive somebody editing this
    -- file by hand -- and in particular has to survive a DELETED location,
    -- which now leaves a gap the registry reads straight past.
    line("        locations = {")
    for i, slot in ipairs(s.slots) do
        line(string.format("            [%d] = {%d, %d, %d},", i - 1, slot.x, slot.y, slot.z))
    end
    line("        },")
    line(string.format("        size = {w = %d, h = %d},", s.size.w, s.size.h))
    line(string.format("        spawn = {x = %d, y = %d},", s.spawn.x, s.spawn.y))
    if s.baseWeight and s.baseWeight > 0 then
        line(string.format("        baseWeight = %.1f,", s.baseWeight))
    end


    -- Only ever written as false. Taking a reservoir is the default, so a room
    -- that says nothing here takes one.
    if s.reservoir == false then
        line("        reservoir = false,")
    end

    -- Omitted entirely when nothing was marked, the same way `generator` is:
    -- a room that says nothing here lands its tenants beside the vehicle,
    -- which is what every room did before any of this existed.
    --
    -- author("cab") is what sets both -- it works out which wall you are
    -- standing at and records it as the front. Everything else about where a
    -- tenant comes out is derived from this one edge by Core.relativeFor, so
    -- there is nothing left for an author to add by hand afterwards. That is
    -- the whole gain over the `landing` table this replaced: naming a part of a
    -- van was a judgement about the van, and the author was standing in a room.
    if s.front then
        line(string.format("        front = %q,", s.front))
        if s.cab then
            line("        cab = true,")
        end
    end

    -- Omitted entirely when the session found no generator. Nil means the room
    -- has none by design, and there is no default to fall back on -- writing a
    -- guess here is exactly the failure that put fifty generators on fifty
    -- roofs while fifty good ones sat 17 tiles south.
    if s.power then
        line(string.format("        generator = {x = %d, y = %d, z = %d}", s.power.x, s.power.y, s.power.z))
    end
    line("    })")
    line("")

    line("")
    line("end)")
    line("")

    line("Events[Core.events.OnRegisterVehicles].Add(function()")
    line("")
    line("    Core.registerVehicles({")
    line("        id = " .. quote(s.id) .. ",")
    line("        source = " .. quote(s.id:match("^([^.]+)") or "authored") .. ",")
    line("        rooms = {" .. quote(s.id) .. "},")
    local scripts = {}
    for _, script in ipairs(s.scripts) do
        table.insert(scripts, quote(script))
    end
    line("        scripts = {" .. table.concat(scripts, ", ") .. "}" .. (s.match and "," or ""))
    if s.match then
        line("        -- beats maintaining a literal list of every livery")
        line("        match = function(vehicle)")
        line("            local script = vehicle:getScript()")
        line("            if not script then return false end")
        line("            return tostring(script:getName()):find(" .. quote("^" .. s.match) .. ") ~= nil")
        line("        end")
    end
    line("    })")
    line("")
    line("end)")
    file:close()

    return {"wrote " .. path .. " to your Zomboid/Lua folder",
            string.format("%d location(s) registered; blueprints are captured in game, per slot, on first lease", wanted),
            "copy it into media/lua/server/PhunInteriors/blueprints/ and it registers itself on load"}
end

-- ---------------------------------------------------------------------------
-- One entry point, matching Admin.run. A panel later drives these same calls.
-- ---------------------------------------------------------------------------

local actions = {
    begin = Author.begin,
    cancel = Author.cancel,
    corner = Author.corner,
    spawn = Author.spawn,
    cab = Author.cab,
    power = Author.power,
    at = Author.at,
    strip = Author.strip,
    scripts = Author.scripts,
    baseweight = Author.baseweight,
    sweep = Author.sweep,
    status = Author.status,
    emit = Author.emit
}

function Author.run(action, args)
    local handler = actions[action]
    if not handler then
        local names = {}
        for name in pairs(actions) do
            table.insert(names, name)
        end
        table.sort(names)
        return {"unknown action. try: " .. table.concat(names, ", ")}
    end
    local ok, result = pcall(handler, args or {})
    if not ok then
        Core.logLn("author action " .. tostring(action) .. " failed: " .. tostring(result))
        return {"that failed: " .. tostring(result)}
    end
    return result
end

return Author
