if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = require "PhunInteriors/manifest"
local Author = {}
Core.modules.author = Author

-- ---------------------------------------------------------------------------
-- Authoring a room set.
--
-- A map author has to hand write two things today: the registerRoomSet call,
-- which is nothing but coordinates, and the blueprints. Both are readable
-- straight out of the map by standing in it, and both fail silently when they
-- are wrong -- a bad origin means the room never loads, a bad exit tile means
-- the door does nothing. So neither should be typed.
--
-- This builds a room set from where the author is standing and emits the lua
-- that registers it. The emitted file is shipped in the mod and loads itself;
-- there is no runtime file reading anywhere in this design.
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
        exits = {},
        spawn = nil,
        power = nil,
        count = nil,
        pitch = nil,
        scripts = {},
        match = args.match,
        requires = args.requires or {trunk = true},
        blueprints = {}
    }

    return {
        "authoring " .. id,
        "stand in one corner of the FIRST room and call author('corner'), then the opposite corner",
        "then: spawn, exit, power, strip, scripts, sweep, emit"
    }
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
    if not s then return {err} end

    local x, y, z = playerPosition()
    if not x then return {"could not find you"} end

    if #s.corners >= 2 then
        s.corners = {}
    end
    table.insert(s.corners, {x = x, y = y, z = z})

    if #s.corners < 2 then
        return {string.format("corner 1 at %d,%d,%d -- now stand in the opposite corner", x, y, z)}
    end

    local a, b = s.corners[1], s.corners[2]
    -- The author stands in corners in whatever order suits them, so normalise
    -- rather than requiring north-west first.
    s.origin = {x = math.min(a.x, b.x), y = math.min(a.y, b.y), z = math.min(a.z, b.z)}
    s.size = {w = math.abs(a.x - b.x) + 1, h = math.abs(a.y - b.y) + 1}

    return {string.format("room is %dx%d with its origin at %d,%d,%d",
        s.size.w, s.size.h, s.origin.x, s.origin.y, s.origin.z)}
end

--- Tiles are recorded relative to the slot origin, which is what the registry
--- wants and what makes one blueprint apply to every slot in the strip.
local function relative(s)
    local x, y, z = playerPosition()
    if not x then
        return nil, "could not find you"
    end
    if not s.origin then
        return nil, "mark the room corners first"
    end
    return {x = x - s.origin.x, y = y - s.origin.y, z = z - s.origin.z}
end

function Author.spawn()
    local s, err = need()
    if not s then return {err} end
    local at, why = relative(s)
    if not at then return {why} end
    s.spawn = at
    return {string.format("spawn tile is %d,%d in the room", at.x, at.y)}
end

function Author.exit()
    local s, err = need()
    if not s then return {err} end
    local at, why = relative(s)
    if not at then return {why} end

    -- Stepping on the same tile twice removes it, so a misplaced exit is
    -- undone by standing on it again rather than by restarting.
    for i, existing in ipairs(s.exits) do
        if existing.x == at.x and existing.y == at.y then
            table.remove(s.exits, i)
            return {string.format("removed the exit at %d,%d (%d left)", at.x, at.y, #s.exits)}
        end
    end

    table.insert(s.exits, {x = at.x, y = at.y})
    return {string.format("exit tile at %d,%d (%d total)", at.x, at.y, #s.exits)}
end

function Author.power()
    local s, err = need()
    if not s then return {err} end
    local at, why = relative(s)
    if not at then return {why} end
    s.power = at
    return {string.format("power square at %d,%d,%d in the room", at.x, at.y, at.z)}
end

--- How the strip repeats. The author laid it out, so they know; deriving it by
--- scanning would need every slot loaded, which is the thing we are trying to
--- avoid making a precondition.
function Author.strip(args)
    local s, err = need()
    if not s then return {err} end

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
        return {string.format("pitchX %d is narrower than the room (%d wide); rooms would overlap",
            pitchX, s.size.w)}
    end
    if pitchY ~= 0 and pitchY < s.size.h then
        return {string.format("pitchY %d is shorter than the room (%d deep); rooms would overlap",
            pitchY, s.size.h)}
    end

    s.count = count
    s.pitch = {x = pitchX, y = pitchY}
    return {string.format("%d rooms, %d apart on %s", count,
        pitchX ~= 0 and pitchX or pitchY, pitchX ~= 0 and "x" or "y")}
end

--- What the fitted-out room weighs empty.
function Author.baseweight(args)
    local s, err = need()
    if not s then return {err} end
    s.baseWeight = tonumber(args and args.base) or 0
    return {string.format("an empty room of this set weighs %.1f", s.baseWeight)}
end

--- Which vehicles get this interior.
function Author.scripts(args)
    local s, err = need()
    if not s then return {err} end

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

--- A room set definition good enough to scan with, before it is registered.
local function provisional(s)
    return {
        id = s.id,
        origin = s.origin,
        pitch = s.pitch,
        count = s.count,
        size = s.size,
        spawn = s.spawn or {x = 1, y = 1},
        exits = s.exits,
        power = s.power or {x = 0, y = 0, z = 1}
    }
end

--- Scan every slot whose chunk happens to be loaded right now.
--
-- Called repeatedly as the author walks the strip. It reports what it still
-- owes rather than failing, because sweeping a 38 room strip is a walk and the
-- author needs to know when they are done.
function Author.sweep()
    local s, err = need()
    if not s then return {err} end
    if not s.origin or not s.count then
        return {"mark the corners and set the strip first"}
    end

    local set = provisional(s)
    local captured, already, missing = 0, 0, {}

    for index = 0, s.count do
        if s.blueprints[index] then
            already = already + 1
        else
            local blueprint = Manifest.scanSlot(set, index)
            if blueprint then
                s.blueprints[index] = blueprint
                captured = captured + 1
            else
                table.insert(missing, index)
            end
        end
    end

    local lines = {string.format("swept: %d new, %d already had, %d still missing",
        captured, already, #missing)}

    if #missing > 0 then
        local shown = {}
        for i = 1, math.min(12, #missing) do
            table.insert(shown, tostring(missing[i]))
        end
        table.insert(lines, "walk to slot(s): " .. table.concat(shown, ", ") ..
            (#missing > 12 and (" and " .. (#missing - 12) .. " more") or ""))
        table.insert(lines, string.format("slot n starts at %d,%d",
            s.origin.x + (s.pitch.x * (missing[1] or 0)),
            s.origin.y + (s.pitch.y * (missing[1] or 0))))
    else
        table.insert(lines, "every slot captured -- ready to emit")
    end

    return lines
end

function Author.status()
    local s, err = need()
    if not s then return {err} end

    local have = 0
    for _ in pairs(s.blueprints) do
        have = have + 1
    end

    return {
        "id: " .. s.id,
        "origin: " .. (s.origin and string.format("%d,%d,%d", s.origin.x, s.origin.y, s.origin.z) or "not set"),
        "size: " .. (s.size and (s.size.w .. "x" .. s.size.h) or "not set"),
        "strip: " .. (s.count and string.format("%d rooms, pitch %d,%d", s.count, s.pitch.x, s.pitch.y) or "not set"),
        "spawn: " .. (s.spawn and (s.spawn.x .. "," .. s.spawn.y) or "not set"),
        "exits: " .. #s.exits,
        "base weight: " .. tostring(s.baseWeight or 0),
        "power: " .. (s.power and string.format("%d,%d,%d", s.power.x, s.power.y, s.power.z) or "default"),
        "scripts: " .. #s.scripts,
        "blueprints: " .. have .. " of " .. ((s.count or 0) + 1)
    }
end

-- ---------------------------------------------------------------------------
-- Emitting
--
-- The output is lua, not json, and that is the whole point of the design: a
-- file dropped in media/lua/server/PhunInteriors/blueprints/ is loaded by the
-- game on boot and registers itself. No file reading at runtime, no parser, no
-- paths to get wrong, and it works identically on a dedicated server from the
-- first tick rather than accumulating as players happen to visit rooms.
-- ---------------------------------------------------------------------------

--- One palette for the whole set rather than one per room.
--
-- Rooms in a strip are variations on a theme and share nearly every sprite, so
-- a shared palette is a large saving over the per room palettes the runtime
-- format uses. Runtime captures one room at a time and has nothing to share
-- with; an export sees all of them at once.
local function poolPalette(blueprints)
    local palette = {}
    local index = {}
    local slots = {}

    for slot, blueprint in pairs(blueprints) do
        local remapped = {}
        for key, entry in pairs(blueprint.squares) do
            local indices = {}
            for i = 1, #entry do
                local name = blueprint.palette[entry[i]]
                if name then
                    local id = index[name]
                    if not id then
                        table.insert(palette, name)
                        id = #palette
                        index[name] = id
                    end
                    table.insert(indices, id)
                end
            end
            if #indices > 0 then
                remapped[key] = indices
            end
        end
        slots[slot] = remapped
    end

    return palette, slots
end

local function quote(str)
    return '"' .. tostring(str):gsub('"', '\\"') .. '"'
end

local function listOf(numbers)
    local parts = {}
    for i = 1, #numbers do
        parts[i] = tostring(numbers[i])
    end
    return table.concat(parts, ",")
end

--- Squares written in sorted key order so re-exporting an unchanged map
--- produces an identical file. Without that every export is a full diff and
--- the file stops being reviewable in git, which is half the reason for
--- shipping lua rather than a blob.
local function sortedKeys(t)
    local keys = {}
    for key in pairs(t) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

function Author.emit(args)
    local s, err = need()
    if not s then return {err} end

    local problems = {}
    if not s.origin or not s.size then table.insert(problems, "room corners not marked") end
    if not s.count then table.insert(problems, "strip not set") end
    if not s.spawn then table.insert(problems, "spawn tile not set") end
    if #s.exits == 0 then table.insert(problems, "no exit tiles marked") end
    if #s.scripts == 0 and not s.match then table.insert(problems, "no vehicle scripts bound") end
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
    local wanted = s.count + 1
    if have < wanted and not (args and args.partial) then
        return {
            string.format("only %d of %d slots captured; sweep the rest first", have, wanted),
            "or pass {partial = true} to emit what you have -- missing slots fall back at runtime"
        }
    end

    local palette, slots = poolPalette(s.blueprints)
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
    line("-- Room set " .. s.id .. ", " .. wanted .. " slots, " .. have .. " captured.")
    line("-- Drop this in media/lua/server/PhunInteriors/blueprints/ and ship it.")
    line("")
    line("local Core = PhunInteriors")
    line("")
    line("Events[Core.events.OnReady].Add(function()")
    line("")
    line("    Core.registerRoomSet(" .. quote(s.id) .. ", {")
    line("        label = " .. quote(s.label) .. ",")
    line("        source = " .. quote(s.id:match("^([^.]+)") or "authored") .. ",")
    line(string.format("        origin = {x = %d, y = %d, z = %d},", s.origin.x, s.origin.y, s.origin.z))
    line(string.format("        pitch = {x = %d, y = %d},", s.pitch.x, s.pitch.y))
    line(string.format("        count = %d,", s.count))
    line(string.format("        size = {w = %d, h = %d},", s.size.w, s.size.h))
    line(string.format("        spawn = {x = %d, y = %d},", s.spawn.x, s.spawn.y))
    if s.baseWeight and s.baseWeight > 0 then
        line(string.format("        baseWeight = %.1f,", s.baseWeight))
    end

    local exits = {}
    for _, exit in ipairs(s.exits) do
        table.insert(exits, string.format("{x = %d, y = %d}", exit.x, exit.y))
    end
    line("        exits = {" .. table.concat(exits, ", ") .. "},")

    local power = s.power or {x = 0, y = 0, z = 1}
    line(string.format("        power = {x = %d, y = %d, z = %d}", power.x, power.y, power.z))
    line("    })")
    line("")

    line("    Core.registerVehicleClass(" .. quote(s.id) .. ", {")
    line("        roomSet = " .. quote(s.id) .. ",")
    line("        source = " .. quote(s.id:match("^([^.]+)") or "authored") .. ",")
    local requires = {}
    for key, value in pairs(s.requires or {}) do
        table.insert(requires, key .. " = " .. tostring(value))
    end
    line("        requires = {" .. table.concat(requires, ", ") .. "},")
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

    line("    Core.registerBlueprints(" .. quote(s.id) .. ", {")
    line("        version = 2,")
    local names = {}
    for _, name in ipairs(palette) do
        table.insert(names, quote(name))
    end
    line("        palette = {" .. table.concat(names, ", ") .. "},")
    line("        slots = {")
    for slot = 0, s.count do
        local squares = slots[slot]
        if squares then
            local parts = {}
            for _, key in ipairs(sortedKeys(squares)) do
                table.insert(parts, "[" .. quote(key) .. "]={" .. listOf(squares[key]) .. "}")
            end
            line("            [" .. slot .. "] = {" .. table.concat(parts, ",") .. "},")
        end
    end
    line("        }")
    line("    })")
    line("")
    line("end)")
    file:close()

    return {
        "wrote " .. path .. " to your Zomboid/Lua folder",
        string.format("%d slots, %d shared sprites in the palette", have, #palette),
        "copy it into media/lua/server/PhunInteriors/blueprints/ and it registers itself on load"
    }
end

-- ---------------------------------------------------------------------------
-- One entry point, matching Admin.run. A panel later drives these same calls.
-- ---------------------------------------------------------------------------

local actions = {
    begin = Author.begin,
    cancel = Author.cancel,
    corner = Author.corner,
    spawn = Author.spawn,
    exit = Author.exit,
    power = Author.power,
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
