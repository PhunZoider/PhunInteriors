-- Transit.sendTo: another mod picks the destination, and the player gets the
-- rest of an exit rather than a bare teleport.
--
-- The failure this exists to prevent is silent. A teleport that bypasses the
-- occupancy leaves the leash, the lease and the client's "Step outside" all
-- believing the player is still in the room, and nothing errors: PhunSpawn's
-- first picker did exactly that. So the checks are on the state left behind,
-- not on the teleport.
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

function getTimestampMs()
    return 1000
end

local Transit = require "PhunInteriors/transit"
local Slots = require "PhunInteriors/slots"
local report = stubs.reporter()
local check = report.check

local sent = {}
Core.respond = function(player, command, args)
    table.insert(sent, {command = command, args = args})
end
local function lastTeleport()
    for i = #sent, 1, -1 do
        if sent[i].command == Core.commands.teleport then
            return sent[i].args
        end
    end
    return nil
end

local function player(name)
    local md = {}
    return {
        getUsername = function() return name end,
        getModData = function() return md end,
        getX = function() return 0 end,
        getY = function() return 0 end,
        getZ = function() return 0 end
    }
end

-- ---------------------------------------------------------------------------
-- Refusals come back as reasons, and send nothing.
-- ---------------------------------------------------------------------------
local nobody = player("nobody")
check("no destination is refused", Transit.sendTo(nobody, nil), false)
check("a destination with no x is refused", Transit.sendTo(nobody, {y = 5}), false)
check("and nothing was sent for either", lastTeleport(), nil)

-- ---------------------------------------------------------------------------
-- Not in a room: only the arrival half.
-- ---------------------------------------------------------------------------
local walker = player("walker")
check("outside a room it succeeds", Transit.sendTo(walker, {x = 10.7, y = 20.2, z = 0}, "test"), true)
local port = lastTeleport()
check("the teleport is floored to a square", port and port.x, 10)
check("and says they are not inside", port and port.inside, false)
check("with no vehicle to go looking for", port and port.rejoin, false)
check("and asks for the arrival report the shove waits on", port and port.report, true)
check("which the server answers without looking for a vehicle", Transit.arrived(walker, nil, nil), true)
check("and only once", Transit.arrived(walker, nil, nil), false)

-- ---------------------------------------------------------------------------
-- In a room: a real exit, to somewhere else.
-- ---------------------------------------------------------------------------
sent = {}
-- Later than the lease's lastSeen, so a renewal is visible.
stubs.worldAge = 50
local tenant = player("tenant")
Slots.store().assignments["v1"] = {room = "gone", index = 0, lastSeen = 0}
Transit.setOccupancy(tenant, {
    vehicleId = "v1",
    room = "gone",
    index = 0,
    seat = 2,
    standSeat = 1,
    zombieSnapshot = 0,
    enteredFrom = {x = 1, y = 2, z = 0}
})
check("inside a room it succeeds", Transit.sendTo(tenant, {x = 500, y = 600, z = 0}, "test"), true)
check("the occupancy is gone", Transit.occupancyOf(tenant), nil)
check("so the leash has nobody to watch", Transit.anyoneInside(), false)
check("and the entrance with it", Transit.entranceOf(tenant), nil)
port = lastTeleport()
check("they go where they were sent, not to the holder", port and port.x, 500)
check("the client is told they are out", port and port.inside, false)
check("with no vehicle to climb back into", port and port.rejoin, false)
check("and no seat", port and port.seat, nil)
check("and no door to stand at", port and port.standSeat, nil)
check("the lease is kept when not released", Slots.find("v1") ~= nil, true)
check("and renewed rather than left to age", Slots.find("v1").lastSeen ~= 0, true)
check("the arrival only clears the ground", Transit.arrived(tenant, nil, nil), true)

-- Released: the room goes back to the pool.
local leaver = player("leaver")
Slots.store().assignments["v2"] = {room = "gone", index = 1, lastSeen = 0}
Transit.setOccupancy(leaver, {vehicleId = "v2", room = "gone", index = 1, seat = -1, zombieSnapshot = 0})
check("a release succeeds", Transit.sendTo(leaver, {x = 5, y = 5}, "test", true), true)
check("and hands the room back", Slots.find("v2"), nil)

-- ---------------------------------------------------------------------------
-- Handing back waits for the last one out, and a single use room hands back
-- by itself. Pulling a lease out from under somebody still inside would leave
-- the leash containing them against a room nobody holds.
-- ---------------------------------------------------------------------------
local function queued(roomId, index)
    for _, entry in ipairs(Slots.store().quarantine) do
        if entry.room == roomId and entry.index == index then
            return true
        end
    end
    return false
end
local function inside(p, holder, roomId)
    Transit.setOccupancy(p, {vehicleId = holder, room = roomId, index = 0, seat = -1, zombieSnapshot = 0})
end

Core.registerRoom("su.room", {size = {w = 2, h = 2}, singleUse = true, locations = {[0] = {0, 7000, 0}}})
Core.registerRoom("su.plain", {size = {w = 2, h = 2}, locations = {[0] = {0, 7100, 0}}})
check("singleUse registers as a boolean", Core.rooms["su.room"].singleUse, true)
check("and defaults off", Core.rooms["su.plain"].singleUse, false)

local first, second = player("first"), player("second")
Slots.acquireIn("s1", "su.room", 0)
inside(first, "s1", "su.room")
inside(second, "s1", "su.room")
check("the first of two out succeeds", Transit.sendTo(first, {x = 5, y = 5}, "test"), true)
check("and the room stays leased for the one still inside", Slots.find("s1") ~= nil, true)
check("the last one out succeeds", Transit.sendTo(second, {x = 5, y = 5}, "test"), true)
check("and a single use room hands itself back", Slots.find("s1"), nil)
-- No blueprint in a spec, so the scrub on the way out cannot run; the slot
-- waits in quarantine exactly as an ordinary release leaves it.
check("into quarantine when the scrub cannot run", queued("su.room", 0), true)

-- An explicit release waits for the last one out too. It used to hand the
-- room back regardless.
local third, fourth = player("third"), player("fourth")
Slots.acquireIn("p1", "su.plain", 0)
inside(third, "p1", "su.plain")
inside(fourth, "p1", "su.plain")
check("a release with somebody still inside succeeds", Transit.sendTo(third, {x = 5, y = 5}, "test", true), true)
check("but keeps the room for them", Slots.find("p1") ~= nil, true)
check("and an ordinary room with nobody left keeps its lease", Transit.sendTo(fourth, {x = 5, y = 5}, "test"), true)
check("because it is not single use", Slots.find("p1") ~= nil, true)

os.exit(report.finish("sendto") == 0 and 0 or 1)
