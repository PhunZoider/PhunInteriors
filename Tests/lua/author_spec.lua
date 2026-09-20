-- Drives PhunInteriors.author through a whole session and then loads the file
-- it emits back into a fresh registry.
--
-- Worth the trouble because the emitter is how every shipped room set gets
-- built, its output is only exercised on the next boot, and a mistake in it is
-- a map's worth of work written out wrong. Two bugs came out of writing this:
-- an emitted `[0] = ...` slot table that ipairs would have silently dropped
-- slot 0 from, and a blueprint loop still reading a session field that had
-- been removed.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

local report = stubs.reporter()
local check = report.check

-- Where the imaginary admin is standing.
local me = {
    x = 0,
    y = 0,
    z = 0
}
Core.tools = Core.tools or {}
Core.tools.onlinePlayers = function()
    return {
        size = function()
            return 1
        end,
        get = function()
            return {
                getX = function()
                    return me.x
                end,
                getY = function()
                    return me.y
                end,
                getZ = function()
                    return me.z
                end
            }
        end
    }
end
local function standAt(x, y, z)
    me.x, me.y, me.z = x, y, z
end

-- getFileWriter, writing somewhere we can read back.
local emitted
local outPath = os.getenv("TEMP") or "."
outPath = outPath:gsub("\\", "/") .. "/pi_author_spec.lua"
function getFileWriter(name)
    emitted = name
    local fh = assert(io.open(outPath, "w"))
    return {
        write = function(_, text)
            fh:write(text)
        end,
        close = function()
            fh:close()
        end
    }
end

-- A world just real enough for Manifest.scan: squares carrying objects that
-- carry sprites. Every room is identical apart from one, which gets an extra
-- shelf, so the emitted file shows per-slot blueprints differing over a shared
-- palette rather than one blueprint repeated.
local FLOOR = "floors_interior_tiles_01_0"
local WALL = "walls_interior_house_01_12"
local SWITCH = "lighting_indoor_01_1"
local SHELF = "furniture_shelving_01_4"
local RESERVOIR = "carpentry_02_122"

local function object(name, class, modData)
    return {
        class = class,
        getSprite = function()
            return {
                getName = function()
                    return name
                end
            }
        end,
        hasModData = function()
            return modData ~= nil
        end,
        getModData = function()
            return modData or {}
        end
    }
end

local function list(items)
    return {
        size = function()
            return #items
        end,
        get = function(_, i)
            return items[i + 1]
        end
    }
end

function instanceof(o, className)
    return o ~= nil and o.class == className
end

function getCell()
    return {
        getGridSquare = function(_, x, y, z)
            local floor = object(FLOOR)
            local objects = {floor}
            if z == 0 then
                -- a wall down the west edge of every room
                if x == 22538 or x == 22562 or x == 22586 then
                    table.insert(objects, object(WALL))
                end
                -- one light switch per room, on the north-west corner
                if y == 11779 and (x == 22538 or x == 22562 or x == 22586) then
                    table.insert(objects, object(SWITCH))
                end
                -- the middle room got a shelf the others did not
                if x == 22563 and y == 11780 then
                    table.insert(objects, object(SHELF))
                end
                -- loot on the floor: must NOT be captured, it is contents
                if y == 11781 then
                    table.insert(objects, object("Base.Nails", "IsoWorldInventoryObject"))
                end
            elseif z == 1 and x == 22539 and y == 11780 then
                -- a reservoir a tenant installed on the first room's roof:
                -- must NOT be captured, or every scrub would restore it
                table.insert(objects, object(RESERVOIR, "IsoThumpable", {
                    [PhunInteriors.consts.reservoirKey] = true
                }))
            end
            return {
                getFloor = function()
                    return floor
                end,
                getObjects = function()
                    return list(objects)
                end
            }
        end
    }
end

local Author = require "PhunInteriors/author"

-- ---- drive a session ------------------------------------------------------
Author.run("begin", {
    id = "spec.van",
    label = "Spec van"
})

-- A 5x15 room with its north-west corner at 22538,11779.
standAt(22538, 11779, 0)
Author.run("corner")
standAt(22542, 11793, 0)
Author.run("corner")

standAt(22540, 11781, 0)
Author.run("spawn")
-- Standing in the north doorway of a 5x15 room marks the NORTH wall as the
-- way into the cab. The room runs y 11779..11793, so y = 11779 is 0 from the
-- north edge and 14 from the south: the nearest wall wins.
standAt(22540, 11779, 0)
Author.run("cab")

-- The generator, 6 south of the room's south edge and a level up.
standAt(22540, 11799, 1)
Author.run("power")

-- Two more rooms at the 24 pitch, placed by standing in them.
standAt(22562, 11779, 0)
Author.run("at")
standAt(22586, 11779, 0)
Author.run("at")

Author.run("scripts", {
    scripts = "Base.Van, Base.VanSeats",
    match = "Van"
})
Author.run("baseweight", {
    base = 40
})

local status = Author.run("status")
check("status reports three rooms", status[4]:match("^rooms: (%d+)"), "3")

-- Sweeping reads the rooms out of the world above.
local swept = Author.run("sweep")
check("swept every slot", swept[2], "every slot captured -- ready to emit")

local result = Author.run("emit")
check("emitted a file", emitted, "PhunInteriors_spec_van.lua")
check("all three locations emitted", result[2]:match("^(%d+) location"), "3")
check("and says blueprints are captured in game", result[2]:match("captured in game") ~= nil, true)

-- ---- load it back ---------------------------------------------------------
local chunk, err = loadfile(outPath)
check("emitted file parses", chunk ~= nil, true)
if not chunk then
    print("  " .. tostring(err))
    os.exit(1)
end
chunk()

-- Nothing is registered until the events fire, which is the contract the file
-- is written against.
check("nothing registered yet", Core.rooms["spec.van"], nil)
triggerEvent(Core.events.OnRegisterRooms, Core)
triggerEvent(Core.events.OnRegisterVehicles, Core)

local room = Core.rooms["spec.van"]
check("room came back", room ~= nil, true)
check("all three locations", #room.indices, 3)
check("slot 0 survived the round trip", Core.slotOrigin(room, 0).x, 22538)
check("slot 1", Core.slotOrigin(room, 1).x, 22562)
check("slot 2", Core.slotOrigin(room, 2).x, 22586)
check("size", room.size.w .. "x" .. room.size.h, "5x15")
check("spawn is relative", room.spawn.x .. "," .. room.spawn.y, "2,2")
-- author("cab") records the wall as the FRONT and sets the flag, because a cab
-- is always at the front of the thing. One act, one fact, two fields that
-- cannot disagree -- where the old landing table could carry a cab on one edge
-- and a contradictory area name on another.
check("the marked wall came back as the front edge", room.front, "north")
check("and it is flagged as the cab", room.cab, true)
check("generator is relative", room.generator.x .. "," .. room.generator.y .. "," .. room.generator.z, "2,20,1")
check("base weight carried", room.baseWeight, 40)

local binding = Core.bindings["spec.van"]
check("binding came back", binding ~= nil, true)
check("scripts bound", #binding.scripts, 2)
check("matcher survived as a function", type(binding.match), "function")

local function fakeVehicle(scriptName)
    return {
        getScript = function()
            return {
                getFullName = function() return scriptName end,
                getName = function() return scriptName end
            }
        end
    }
end
check("bound to its own room", Core.roomsForVehicle(fakeVehicle("Base.Van"))[1], "spec.van")
check("matcher matches", binding.match(fakeVehicle("VanSpiffo")), true)
check("matcher rejects", binding.match(fakeVehicle("Sedan")), false)
-- The matcher is what reaches a livery the script list never named.
check("a matched livery resolves to the room",
    Core.roomsForVehicle(fakeVehicle("VanSpiffo"))[1], "spec.van")
check("and an unrelated script does not", #Core.roomsForVehicle(fakeVehicle("Sedan")), 0)

-- The emitted file no longer carries a blueprint. It is the CONTRACT only --
-- shape, spawn, exits, generator, locations, and which vehicles fit.
check("no blueprint is shipped", Core.blueprints["spec.van"], nil)

-- ---- capture, which is where blueprints come from now ---------------------
local Manifest = require "PhunInteriors/manifest"
Core.data = {}

local captured = Manifest.captureSlot("spec.van", 0)
check("slot 0 captured", captured ~= nil, true)
-- Wall, switch, shelf. Not the floor -- isStructural excludes it by identity
-- against square:getFloor(), because the scrub keeps the floor rather than
-- rebuilding it. Not the loose Nails either; those are contents.
check("palette holds the structure only", #captured.palette, 2)
check("the floor is not in it", captured.palette[1] ~= "floors_interior_tiles_01_0", true)
-- Keys are relative to the slot origin, which is what lets a blueprint be
-- applied to the slot it was read from wherever that slot sits on the map.
check("keys are relative", captured.squares["0,0,0"] ~= nil, true)

-- Loot on the floor is contents and must never reach a blueprint, or a scrub
-- would treat it as part of the room and put it back.
local nailsInPalette = false
for _, name in ipairs(captured.palette) do
    if name == "Base.Nails" then
        nailsInPalette = true
    end
end
check("loose items are not structure", nailsInPalette, false)

-- Same for a reservoir a tenant installed, which is tagged. Captured, it would
-- be restored by every scrub as a picture of a barrel. An untagged barrel is
-- the map's own and is captured like any fixture; this one is not.
local reservoirInPalette = false
for _, name in ipairs(captured.palette) do
    if name == RESERVOIR then
        reservoirInPalette = true
    end
end
check("an installed reservoir is not structure", reservoirInPalette, false)
check("and leaves no key on the roof square", captured.squares["1,1,1"], nil)

-- The spec world gives slot 1 a shelf the others do not have. That is the
-- whole point of capturing per slot: slot 1 keeps its shelf and slot 0 does
-- not, so a scrub restores each stamp to what the author actually built there.
Manifest.captureSlot("spec.van", 1)
check("slot 0 has no shelf", Manifest.forSlot("spec.van", 0).squares["1,1,0"], nil)
check("slot 1 kept its shelf", #Manifest.forSlot("spec.van", 1).squares["1,1,0"], 1)

-- Stored per slot, under ONE palette shared by the room -- the pooling that
-- stops a near-identical stamp costing a second copy of every sprite name.
local stored = Core.data.roomManifests["spec.van"]
check("stored per slot", (stored.slots[0] and stored.slots[1]) ~= nil, true)
check("one pooled palette", stored.palette ~= nil, true)
check("the shelf added one entry, not a whole palette", #stored.palette, 3)
-- The pooled indices have to be remapped out of each scan's own local palette,
-- or slot 1's sprites would silently come back as slot 0's.
local shelf = Manifest.forSlot("spec.van", 1).squares["1,1,0"][1]
check("shelf resolves through the pooled palette",
    Manifest.forSlot("spec.van", 1).palette[shelf], "furniture_shelving_01_4")

-- Resolution order: the slot's own capture wins. A slot that never captured
-- falls through to a sibling rather than being unscrubbable forever.
check("captured beats everything", select(2, Manifest.forSlot("spec.van", 0)), "captured")
check("an uncaptured slot borrows", select(2, Manifest.forSlot("spec.van", 2)), "sibling")
check("and only a room with nothing at all resolves to nil",
    Manifest.forSlot("spec.nothing", 0), nil)

-- Re-exporting an unchanged session must produce an identical file, or every
-- export is a full diff and the emitted lua stops being reviewable.
local first = assert(io.open(outPath, "r")):read("*a")
Author.run("emit")
local second = assert(io.open(outPath, "r")):read("*a")
check("re-export is byte identical", first == second, true)

if os.getenv("PI_KEEP_SAMPLE") then
    print("  sample written to " .. outPath)
else
    os.remove(outPath)
end
os.exit(report.finish("author") == 0 and 0 or 1)
