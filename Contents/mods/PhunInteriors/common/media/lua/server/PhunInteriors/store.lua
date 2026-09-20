if isClient() then
    return
end
require "PhunInteriors/core"
require "PhunInteriors/overrides"
local Core = PhunInteriors
local json = require "PhunInteriors/json"
local Store = {}
Core.modules.store = Store

-- ---------------------------------------------------------------------------
-- The override file.
--
-- One file, PhunInteriors.json, in the game's Lua folder -- beside
-- PhunMart_Shops.json and the rest, and reached with the same two calls,
-- because an admin who already runs a Phun server knows where to look and what
-- to expect. PhunMart splits its overrides across seven files, one per kind;
-- this mod has two kinds and no history of hand-maintained splits, so one file
-- is one thing to find, back up and diff.
--
-- SERVER SIDE ONLY, and not merely by convention. getFileReader resolves
-- against the Lua folder of whichever machine is running, so a client reading
-- it would read its own, which on a dedicated server is somebody else's
-- customisations or nothing at all. The client is told the state of the
-- registry over the wire, the way it already is for the room list.
--
-- It is written by the editor and it is meant to be read by a person: sorted
-- keys and two-space indentation, so a server admin can diff one save against
-- the next and see what changed. That is most of why it is here rather than in
-- GlobalModData, which is a binary blob nobody can inspect or put in git.
-- ---------------------------------------------------------------------------

Store.FILE = "PhunInteriors.json"

--- Whole file as one string, or nil when it is not there.
---
--- `false` to getFileReader, so a missing file stays missing. Passing true
--- creates an empty one, and an empty file is not the same as no file: the
--- decode below would report it as malformed on every boot of a server that
--- has never customised anything.
local function readAll(filename)
    local reader = getFileReader(filename, false)
    if not reader then
        return nil
    end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(lines, "\n")
end

--- Read the file and put everything in it on.
---
--- Never throws and never refuses to boot. A file that cannot be read is
--- reported and ignored, because the alternative -- a server that will not
--- start because of a stray comma in a customisation file -- is worse than one
--- that starts stock and says so loudly.
--- @return the number of rooms patched, and a list of complaints
function Store.load()
    local text = readAll(Store.FILE)
    if not text or text == "" then
        Core.debugLn("no " .. Store.FILE .. "; running the shipped registry")
        return 0, {}
    end

    local doc, err = json.decode(text)
    if err then
        Core.logLn("could not read " .. Store.FILE .. ": " .. tostring(err))
        Core.logLn("no customisations are being applied, and the file has not been changed")
        return 0, {tostring(err)}
    end

    local problems = Core.installOverrides(doc)
    local rooms, bindings = 0, 0
    for _ in pairs(Core.overrides.rooms) do
        rooms = rooms + 1
    end
    for _ in pairs(Core.overrides.bindings) do
        bindings = bindings + 1
    end

    for _, complaint in ipairs(problems) do
        Core.logLn(Store.FILE .. ": " .. complaint)
    end
    Core.logLn(string.format("%s: %d room(s) customised, %d binding(s)%s",
        Store.FILE, rooms, bindings,
        #problems > 0 and (", " .. #problems .. " line(s) ignored") or ""))

    return rooms, problems
end

--- Write everything the editor has changed.
---
--- @return true, or false plus why not
function Store.save()
    local doc = Core.overrideDocument()

    -- Encoded BEFORE the file is opened, and that order is the whole of the
    -- safety here: getFileWriter truncates on open, so opening it and then
    -- discovering there is nothing to write replaces a good file with an empty
    -- one. Same trap PhunMart's saveTable guards, and worth restating because
    -- the natural way to write this code has the two the other way round.
    local text, err = json.encodePretty(doc)
    if not text then
        Core.logLn("refusing to save " .. Store.FILE .. ": " .. tostring(err))
        Core.logLn("the file on disk has been left as it was")
        return false, tostring(err)
    end

    local writer = getFileWriter(Store.FILE, true, false)
    if not writer then
        return false, "could not open " .. Store.FILE .. " for writing"
    end
    writer:write(text)
    writer:close()

    -- Only here, after the write actually happened. Clearing it alongside the
    -- encode would report the registry as saved whenever the file could not be
    -- opened, which is the one case where an admin most needs to be told.
    Core.unsavedEdits = false

    Core.debugLn("wrote " .. Store.FILE)
    return true
end

--- Re-read the file, discarding anything unsaved.
---
--- Every room with a patch is rebuilt from its snapshot first, so a patch
--- REMOVED from the file on disk is actually removed rather than left on from
--- the last load. Reverting the whole set and then reinstalling is the cheap
--- way to say that: installOverrides only ever applies what it finds, so
--- without the pass below a deleted entry would linger until a restart.
function Store.reload()
    local was = {}
    for id in pairs(Core.overrides.rooms) do
        table.insert(was, id)
    end
    Core.overrides.rooms = {}
    for _, id in ipairs(was) do
        Core.applyRoomOverride(id)
    end
    local rooms, problems = Store.load()
    -- The registry now says exactly what the file says, whatever it said a
    -- moment ago. Cleared after load, because installOverrides does not touch
    -- the flag and the reverts above went through setRoomOverride's cousin.
    Core.unsavedEdits = false
    return rooms, problems
end

return Store
