local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/overrides"
local Core = PhunInteriors
local Store = require "PhunInteriors/store"
local json = require "PhunInteriors/json"

local logged = {}
Core.logLn = function(text) table.insert(logged, text) end
Core.debugLn = function() end

local report = stubs.reporter()
local check = report.check

-- ---------------------------------------------------------------------------
-- PhunInteriors.json, written and read back.
--
-- The override file is the only durable state the admin editor has, and every
-- way it can go wrong is silent: a save that encodes to something the reader
-- takes differently loses the admin's work with no error anywhere, and a boot
-- that cannot read it starts stock and carries on. So the round trip is
-- checked rather than assumed.
--
-- The filesystem here is stubs.files, an in-memory table. The real calls
-- resolve against ~/Zomboid/Lua, and a test that wrote there would either need
-- that folder or would write into the developer's own save.
-- ---------------------------------------------------------------------------

local function shippedRooms()
    Core.registerRoom("t.van", {
        label = "Van room",
        size = {w = 3, h = 4},
        spawn = {x = 1, y = 1},
        front = "north",
        generator = {x = 0, y = 17, z = 0},
        locations = {
            [0] = {1000, 1000, 0},
            [1] = {1025, 1000, 0},
            [2] = {1050, 1000, 0}
        }
    })
    Core.registerRoom("t.tent", {
        label = "Tent room",
        size = {w = 3, h = 4},
        locations = {[0] = {2000, 2000, 0}}
    })
end

---------------------------------------------------------------------------
-- 1. No file at all
---------------------------------------------------------------------------

shippedRooms()
local rooms, problems = Store.load()
check("a missing file patches nothing", rooms, 0)
check("and complains about nothing", #problems, 0)
check("the shipped room is untouched", Core.rooms["t.van"].front, "north")

-- Deliberately no file created. getFileReader is called with `false`, because
-- an empty file is not the same as no file: the decode would report it as
-- malformed on every boot of a server that has never customised anything.
check("no file was created by reading", stubs.files["PhunInteriors.json"], nil)

---------------------------------------------------------------------------
-- 2. Save, and what lands on disk
---------------------------------------------------------------------------

Core.setRoomOverride("t.van", {
    front = "south",
    cab = true,
    locations = {[1] = false, [7] = {3000, 3000, 0}}
})
check("editing marks the registry unsaved", Core.unsavedEdits, true)
check("saved", Store.save(), true)
check("saving clears the flag", Core.unsavedEdits, false)

local text = stubs.files["PhunInteriors.json"]
check("something was written", type(text), "string")

-- Laid out, because the whole reason for a file in the Lua folder rather than
-- a blob in GlobalModData is that a person can open it and diff it.
check("it is indented", text:find("\n  ") ~= nil, true)

local doc = json.decode(text)
check("it is valid JSON", type(doc), "table")
check("it carries a version", doc.version, 1)
check("the patched room is in it", doc.rooms["t.van"].front, "south")
check("slot keys are strings on disk", doc.rooms["t.van"].locations["7"][1], 3000)
check("the tombstone is on disk", doc.rooms["t.van"].locations["1"], false)
-- Sparse: the fields nobody changed are absent, so a later version shipping a
-- new default reaches every room the admin had no opinion about.
check("an unchanged field is absent", doc.rooms["t.van"].spawn, nil)
check("an untouched room is absent", doc.rooms["t.tent"], nil)

---------------------------------------------------------------------------
-- 3. Read it back into a fresh registry
---------------------------------------------------------------------------

-- The boot path: register from lua, then put the file on.
Core.rooms = {}
Core.roomDefs = {}
Core.overrides.rooms = {}
Core.overrides.bindings = {}
shippedRooms()
check("fresh registry is stock", Core.roomOverrideState("t.van"), "shipped")

local reloaded, why = Store.load()
check("one room patched", reloaded, 1)
check("no complaints", #why, 0)
check("front came back", Core.rooms["t.van"].front, "south")
check("cab came back", Core.rooms["t.van"].cab, true)
check("the deleted slot is still deleted", Core.slotOrigin(Core.rooms["t.van"], 1), nil)
check("the added slot came back", Core.slotOrigin(Core.rooms["t.van"], 7).x, 3000)
check("the untouched slot is where it was", Core.slotOrigin(Core.rooms["t.van"], 0).x, 1000)
check("the untouched room is untouched", Core.roomOverrideState("t.tent"), "shipped")

-- And the fields nobody patched still come from the lua, which is the whole
-- point of storing a diff rather than a copy.
check("spawn still comes from the code", Core.rooms["t.van"].spawn.x, 1)
check("the generator still comes from the code", Core.rooms["t.van"].generator.y, 17)

---------------------------------------------------------------------------
-- 4. Saving twice produces an identical file
---------------------------------------------------------------------------

-- Keys are sorted for exactly this reason. Without it, pairs() order decides
-- the layout and every save is a full diff, which stops the file being
-- reviewable -- the same failure Author.emit sorts its locations to avoid.
--
-- Asserted as an ORDERING rather than by comparing two encodings, and the
-- difference matters. Encoding the same key set twice -- even built in
-- different insertion orders -- gives the same answer under LuaJIT with the
-- sort removed, so a comparison test passes against a broken copy and proves
-- nothing. PZ runs Kahlua, not LuaJIT, and Lua's hash iteration order is not
-- promised to be stable across implementations or insertions.
--
-- So the check is the property the sort is there for: keys come out
-- alphabetically, whatever the table did.
local ordered = json.encodePretty({front = "south", cab = true, baseWeight = 5, priority = 2})
local seen = {}
for key in ordered:gmatch('"([%w_]+)":') do
    table.insert(seen, key)
end
check("every key was emitted", #seen, 4)
check("keys come out sorted",
    table.concat(seen, ","), "baseWeight,cab,front,priority")

Store.save()
local first = stubs.files["PhunInteriors.json"]
Store.save()
check("re-saving an unchanged registry is byte identical",
    stubs.files["PhunInteriors.json"], first)

---------------------------------------------------------------------------
-- 5. A file that cannot be read
---------------------------------------------------------------------------

-- Reported and ignored, never fatal. A server that will not start because of a
-- stray comma in a customisation file is worse than one that starts stock and
-- says so loudly.
Core.rooms = {}
Core.roomDefs = {}
Core.overrides.rooms = {}
shippedRooms()
stubs.files["PhunInteriors.json"] = "{ this is not json"
logged = {}
local bad, badWhy = Store.load()
check("nothing was patched", bad, 0)
check("it complained", #badWhy > 0, true)
check("the registry is stock", Core.rooms["t.van"].front, "north")
check("and it said so in the log", #logged > 0, true)

-- The file itself is left exactly as it was, so an admin can fix their typo
-- rather than find the file replaced.
check("the bad file was not overwritten", stubs.files["PhunInteriors.json"], "{ this is not json")

---------------------------------------------------------------------------
-- 6. A file with one bad line in it
---------------------------------------------------------------------------

-- Dropped one at a time and named. A whole file refused for one typo loses
-- every other customisation in it.
Core.rooms = {}
Core.roomDefs = {}
Core.overrides.rooms = {}
shippedRooms()
stubs.files["PhunInteriors.json"] = json.encodePretty({
    version = 1,
    rooms = {
        ["t.van"] = {front = "sideways", baseWeight = 30},
        ["t.tent"] = {front = "east"}
    }
})
logged = {}
local partial, partialWhy = Store.load()
check("both rooms still got a patch", partial, 2)
check("the bad field was reported", #partialWhy, 1)
check("the good field in the same room applied", Core.rooms["t.van"].baseWeight, 30)
check("the bad field did not", Core.rooms["t.van"].front, "north")
check("the other room applied", Core.rooms["t.tent"].front, "east")

---------------------------------------------------------------------------
-- 7. Reload discards what was never saved
---------------------------------------------------------------------------

Core.rooms = {}
Core.roomDefs = {}
Core.overrides.rooms = {}
shippedRooms()
stubs.files["PhunInteriors.json"] = json.encodePretty({
    version = 1,
    rooms = {["t.van"] = {front = "south"}}
})
Store.load()
check("the file's patch is on", Core.rooms["t.van"].front, "south")

-- An edit that was never written, then a reload.
Core.setRoomOverride("t.van", {front = "west", baseWeight = 99})
check("the unsaved edit applied", Core.rooms["t.van"].front, "west")

-- And an edit to a room the file does not mention AT ALL. This is the case
-- Store.reload's revert pass exists for, and the only one: installOverrides
-- clears the override table and rebuilds every room it FINDS, so a room the
-- new file is silent about would keep the patched build it already had. A
-- reload that leaves an unsaved edit in place is a Discard button that
-- discards some of it.
Core.setRoomOverride("t.tent", {front = "north", baseWeight = 42})
check("the second unsaved edit applied", Core.rooms["t.tent"].baseWeight, 42)

Store.reload()
check("reload puts the file's value back", Core.rooms["t.van"].front, "south")
check("and drops a field the file never had", Core.rooms["t.van"].baseWeight, 0)
check("a room absent from the file is reverted too", Core.rooms["t.tent"].baseWeight, 0)
check("right down to its front", Core.rooms["t.tent"].front, nil)
check("and it reads as shipped again", Core.roomOverrideState("t.tent"), "shipped")
check("reload leaves nothing unsaved", Core.unsavedEdits, false)

report.finish("store")
