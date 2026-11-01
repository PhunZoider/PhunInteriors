-- Transit.settleSafehouseRespawn: vanilla's safehouse respawn swaps width and
-- height, so any room longer than it is wide puts the new character off its
-- floor. The bug is in where they land, so these checks use its arithmetic
-- rather than a position picked by hand.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

function getTimestampMs()
    return 1000
end

-- A java.util.ArrayList, as far as vanilla's loop asks one.
local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        contains = function(_, wanted)
            for _, item in ipairs(items) do
                if item == wanted then
                    return true
                end
            end
            return false
        end
    }
end

local houses = {}
SafeHouse = {
    getSafehouseList = function() return javaList(houses) end,
    getSafehouseOverlapping = function() return nil end
}

local Transit = require "PhunInteriors/transit"
local Slots = require "PhunInteriors/slots"
local report = stubs.reporter()
local check = report.check

local sent = {}
Core.respond = function(player, command, args)
    table.insert(sent, {player = player, command = command, args = args})
end
local function lastTeleport(p)
    for i = #sent, 1, -1 do
        if sent[i].command == Core.commands.teleport and sent[i].player == p then
            return sent[i].args
        end
    end
    return nil
end

local function player(name, x, y)
    local md = {}
    return {
        getUsername = function() return name end,
        getModData = function() return md end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return 0 end
    }
end

-- Takes the room def, and claims what SafeHouse.addSafeHouse does: the building
-- plus two squares on every side, read off the bytecode and off a real save,
-- which held x=23078 y=12375 w=7 h=13 for the 3x9 floor at 23080,12377.
local function claim(x, y, w, h, owner, ticked, members)
    table.insert(houses, {
        getX = function() return x - 2 end,
        getY = function() return y - 2 end,
        getW = function() return w + 4 end,
        getH = function() return h + 4 end,
        getOwner = function() return owner end,
        getPlayers = function() return javaList(members or {}) end,
        isRespawnInSafehouse = function(_, name) return ticked[name] == true end
    })
end

-- Where MapSpawnSelect:getSafehouseSpawnRegion puts them.
local function vanillaLanding(name, x, y, w, h)
    return player(name, (x - 2) + ((h + 4) / 2), (y - 2) + ((w + 4) / 2))
end

Core.registerRoom("long", {
    size = {w = 4, h = 10},
    spawn = {x = 1, y = 1},
    locations = {[0] = {1000, 1000, 0}, [1] = {1100, 1000, 0}}
})
Core.registerRoom("wallline", {
    size = {w = 4, h = 7},
    spawn = {x = 1, y = 1},
    locations = {[0] = {2000, 1000, 0}}
})
Core.registerRoom("short", {
    size = {w = 3, h = 4},
    spawn = {x = 1, y = 1},
    locations = {[0] = {3000, 1000, 0}}
})

local function lease(holder, roomId, index)
    local assignment = Slots.acquireIn(holder, roomId, index)
    assignment.lastKnownVehiclePos = {x = 50, y = 60, z = 0}
    return assignment
end

-- ---------------------------------------------------------------------------
-- A long room: past the wall, in no slot.
-- ---------------------------------------------------------------------------
lease("uuid-long", "long", 0)
claim(1000, 1000, 3, 9, "a", {a = true})
local a = vanillaLanding("a", 1000, 1000, 3, 9)
check("the landing really is off the footprint",
    Core.inBounds(Core.slotBounds(Core.rooms.long, 0), a:getX(), a:getY(), 0), false)
check("and recover alone cannot find them", Transit.recover(a), false)
check("settling moves them", Transit.settleSafehouseRespawn(a), true)
local tp = lastTeleport(a)
check("to the room's spawn x", tp and tp.x, 1001)
check("and y", tp and tp.y, 1001)
check("as somebody inside it", tp and tp.inside, true)
local occupancy = Transit.occupancyOf(a)
check("contained by the lease on that slot", occupancy and occupancy.vehicleId, "uuid-long")
check("coming out at the holder", occupancy and occupancy.returnTo and occupancy.returnTo.x, 50)
check("with the grace a teleport gets", occupancy and occupancy.graceUntil, 7000)
Transit.setOccupancy(a, nil)

-- ---------------------------------------------------------------------------
-- A 3x6 floor: the east wall line, which recover finds and the leash ejects.
-- ---------------------------------------------------------------------------
lease("uuid-wall", "wallline", 0)
claim(2000, 1000, 3, 6, "b", {b = true})
local b = vanillaLanding("b", 2000, 1000, 3, 6)
check("the landing is inside the footprint",
    Core.inBounds(Core.slotBounds(Core.rooms.wallline, 0), b:getX(), b:getY(), 0), true)
check("but off the floor", Core.inBounds(Core.slotFloor(Core.rooms.wallline, 0), b:getX(), b:getY(), 0), false)
check("so it is moved as well", Transit.settleSafehouseRespawn(b), true)
check("onto the floor", lastTeleport(b) and lastTeleport(b).x, 2001)
check("under the lease", Transit.occupancyOf(b) and Transit.occupancyOf(b).vehicleId, "uuid-wall")
Transit.setOccupancy(b, nil)

-- ---------------------------------------------------------------------------
-- A landing that was right, and characters who are not this case.
-- ---------------------------------------------------------------------------
lease("uuid-short", "short", 0)
claim(3000, 1000, 2, 3, "c", {c = true})
local c = vanillaLanding("c", 3000, 1000, 2, 3)
check("a landing on the floor is left to recover", Transit.settleSafehouseRespawn(c), false)
check("with no teleport", lastTeleport(c), nil)
check("and no occupancy of its own", Transit.occupancyOf(c), nil)

claim(1000, 1000, 3, 9, "d", {})
local d = vanillaLanding("d", 1000, 1000, 3, 9)
check("not an owner who has not ticked the box", Transit.settleSafehouseRespawn(d), false)

-- Ticked, on a claim over a real slot, and standing nowhere near it: vanilla
-- put them somewhere else, such as where they died.
local e = player("e", 8000, 8000)
claim(1000, 1000, 3, 9, "e", {e = true})
check("nobody who spawned somewhere else", Transit.settleSafehouseRespawn(e), false)
check("is pulled across the map", lastTeleport(e), nil)

claim(1000, 1000, 3, 9, "owner", {f = true})
local f = vanillaLanding("f", 1000, 1000, 3, 9)
check("nor somebody ticked on a claim they have left", Transit.settleSafehouseRespawn(f), false)

claim(1000, 1000, 3, 9, "owner", {g = true}, {"g"})
local g = vanillaLanding("g", 1000, 1000, 3, 9)
check("a member counts as well as the owner", Transit.settleSafehouseRespawn(g), true)
Transit.setOccupancy(g, nil)

-- A building that is not one of ours, at the landing vanilla would use.
claim(9000, 9000, 3, 9, "h", {h = true})
local h = vanillaLanding("h", 9000, 9000, 3, 9)
check("a safehouse that is not a room is none of our business", Transit.settleSafehouseRespawn(h), false)

-- ---------------------------------------------------------------------------
-- A claim that outlived its lease: on the floor, and nobody pretends otherwise.
-- ---------------------------------------------------------------------------
claim(1100, 1000, 3, 9, "i", {i = true})
local i = vanillaLanding("i", 1100, 1000, 3, 9)
check("no lease still moves them", Transit.settleSafehouseRespawn(i), true)
check("onto the floor", lastTeleport(i) and lastTeleport(i).x, 1101)
check("not as somebody inside", lastTeleport(i) and lastTeleport(i).inside, false)
check("and with no occupancy", Transit.occupancyOf(i), nil)

-- ---------------------------------------------------------------------------
-- The server's copy of the position has not caught up, which is what a
-- respawn into Camper - Large looked like on a dedicated server.
-- ---------------------------------------------------------------------------
claim(1000, 1000, 3, 9, "j", {j = true})
local j = player("j", 0, 0)
check("the server's copy alone finds nothing", Transit.settleSafehouseRespawn(j), false)
check("the client's report is what moves them", Transit.recoverRespawn(j, {x = 1004.5, y = 1001.5, z = 0}), true)
check("onto the floor", lastTeleport(j) and lastTeleport(j).x, 1001)
check("under the lease", Transit.occupancyOf(j) and Transit.occupancyOf(j).vehicleId, "uuid-long")
Transit.setOccupancy(j, nil)

-- On the floor already: no move, but still contained, with a grace so the
-- leash does not read that same stale copy as a breach.
claim(3000, 1000, 2, 3, "k", {k = true})
local k = player("k", 0, 0)
check("a report on the floor recovers them", Transit.recoverRespawn(k, {x = 3001.5, y = 1001.5, z = 0}), true)
check("with no teleport", lastTeleport(k), nil)
check("under the lease", Transit.occupancyOf(k) and Transit.occupancyOf(k).vehicleId, "uuid-short")
check("and a grace", Transit.occupancyOf(k) and Transit.occupancyOf(k).graceUntil, 7000)
Transit.setOccupancy(k, nil)

local m = player("m", 8000, 8000)
check("a report from nowhere near a room is nothing", Transit.recoverRespawn(m, {x = 8000.5, y = 8000.5, z = 0}), false)
check("and no report falls back on the server's copy", Transit.recoverRespawn(player("n", 3001.5, 1001.5)), true)

os.exit(report.finish("respawn") == 0 and 0 or 1)
