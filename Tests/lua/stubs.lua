-- Just enough of the PZ global surface to load the shared and server files
-- under LuaJIT.
--
-- This is not a mock of the game. It stubs the globals the files touch while
-- *loading*, so the pure-Lua half of the mod -- the registry, slot placement,
-- the reverse indexes, allocation order -- can be exercised without one. Any
-- test that needs an IsoGridSquare belongs in the game, not here.

local stubs = {}

function stubs.install(root)
    local handlers = {}
    local function slot(name)
        handlers[name] = handlers[name] or {fns = {}}
        local s = handlers[name]
        s.Add = s.Add or function(fn) table.insert(s.fns, fn) end
        s.Remove = s.Remove or function() end
        return s
    end

    Events = setmetatable({}, {__index = function(_, k) return slot(k) end})
    LuaEventManager = {AddEvent = function(name) slot(name) end}
    function triggerEvent(name, ...)
        for _, fn in ipairs(slot(name).fns) do fn(...) end
    end

    -- SP: both false, so shared, server and client files all load.
    function isClient() return false end
    function isServer() return false end
    function isCoopHost() return false end

    function getSandboxOptions() return {getOptionByName = function() return nil end} end

    stubs.worldAge = 0
    function getGameTime() return {getWorldAgeHours = function() return stubs.worldAge end} end

    -- An empty world. Core.vehicleNear sweeps 49 squares through this, and
    -- every one coming back nil is the "the vehicle is not loaded" branch --
    -- which is the normal case for a release, so it is the one worth being
    -- able to run. Nothing here pretends to be an IsoGridSquare; a test that
    -- needs a real one belongs in the game.
    function getCell() return {getGridSquare = function() return nil end} end

    -- A world with no edges. Both callers -- placeInside and
    -- Transit.fallbackReturn -- use the meta grid only to refuse coordinates
    -- this world does not have, so saying yes to everything is the "nothing is
    -- out of range" case and is the one every other spec wants. A spec that
    -- cares about the refusal replaces this for the length of the test.
    function getWorld()
        return {
            getMetaGrid = function()
                return {
                    isValidSquare = function() return true end,
                    getMinX = function() return 0 end,
                    getMaxX = function() return 0 end,
                    getMinY = function() return 0 end,
                    getMaxY = function() return 0 end
                }
            end
        }
    end

    local modData = {}
    ModData = {getOrCreate = function(k) modData[k] = modData[k] or {}; return modData[k] end}
    function getOnlinePlayers() return nil end

    -- Sequential rather than random, because a test that asserts on an id is
    -- more use than one that asserts an id exists.
    local uuids = 0
    function getRandomUUID() uuids = uuids + 1; return "uuid-" .. uuids end

    -- The Lua folder, in memory.
    --
    -- Enough to run store.lua end to end, which is worth doing because the
    -- override file is the only piece of durable state the editor has and the
    -- failure mode is silent: a file that saves and reads back as something
    -- slightly different loses an admin's work without an error anywhere.
    --
    -- Deliberately NOT the real filesystem. The game resolves these against
    -- ~/Zomboid/Lua, and a test that wrote there would either need that folder
    -- to exist or would quietly write into the developer's actual save.
    --
    -- getFileWriter TRUNCATES on open, as the real one does. Store.save
    -- encodes before it opens the file precisely because of that, and a stub
    -- that appended instead would let a regression past.
    stubs.files = {}
    function getFileWriter(name, createIfNotExists, append)
        if not append then
            stubs.files[name] = ""
        elseif stubs.files[name] == nil then
            if not createIfNotExists then return nil end
            stubs.files[name] = ""
        end
        return {
            write = function(_, text) stubs.files[name] = (stubs.files[name] or "") .. text end,
            close = function() end
        }
    end

    function getFileReader(name, createIfNotExists)
        if stubs.files[name] == nil then
            if not createIfNotExists then return nil end
            stubs.files[name] = ""
        end
        -- Line at a time, the way the real reader hands it over -- which is
        -- why store.lua reassembles with a newline join rather than reading
        -- the file whole.
        local rest = stubs.files[name]
        local done = false
        return {
            readLine = function()
                if done or rest == nil then return nil end
                local line, tail = rest:match("^([^\n]*)\n(.*)$")
                if line then
                    rest = tail
                    return line
                end
                done = true
                if rest == "" then return nil end
                return rest
            end,
            close = function() end
        }
    end

    -- The mod's own require, resolving "PhunInteriors/x" against the three
    -- source trees the game merges.
    local lua = root .. "/Contents/mods/PhunInteriors/common/media/lua/"
    local loaded = {}
    function require(path)
        if loaded[path] then return loaded[path] end
        loaded[path] = true
        for _, dir in ipairs({"shared/", "server/", "client/"}) do
            local file = lua .. dir .. path .. ".lua"
            local fh = io.open(file, "r")
            if fh then
                fh:close()
                loaded[path] = assert(loadfile(file))() or true
                return loaded[path]
            end
        end
        error("no module " .. path)
    end
end

-- Minimal assertion surface. Deliberately does not stop at the first failure:
-- a placement bug usually breaks several of these at once and the pattern is
-- the diagnosis.
function stubs.reporter()
    local r = {checks = 0, failures = 0}
    function r.check(label, got, want)
        r.checks = r.checks + 1
        if got ~= want then
            r.failures = r.failures + 1
            print(string.format("  FAIL %-52s got %s want %s", label, tostring(got), tostring(want)))
        end
    end
    function r.finish(name)
        print(string.format("%-16s %d checks, %d failures", name, r.checks, r.failures))
        return r.failures
    end
    return r
end

return stubs
