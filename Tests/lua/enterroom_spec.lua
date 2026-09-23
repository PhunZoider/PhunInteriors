-- Transit.enterRoom: another mod puts somebody into a room with nothing
-- holding it, PhunSpawn's arrival room being the first.
--
-- What matters here is the LEASE KEY. It belongs to the lease rather than the
-- player, so a second tenant sharing a full room is a second occupant of the
-- same lease -- and the hand back on the last exit, the reclaim and
-- isOccupied all answer correctly because they compare occupancies against
-- that key. Most of the checks below are about that holding up.
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
Core.settings.BreachEjects = true

function getTimestampMs()
    return 1000
end

-- Mirrors SafeHouse.getSafehouseOverlapping as disassembled, as slots_spec
-- does, plus playerAllowed, which is what Slots.trespassOn asks.
local claims = {}
SafeHouse = {
    getSafehouseOverlapping = function(x1, y1, x2, y2)
        for _, house in ipairs(claims) do
            if x1 < house.x + house.w and x2 > house.x and y1 < house.y + house.h and y2 > house.y then
                return house
            end
        end
        return nil
    end
}

local Transit = require "PhunInteriors/transit"
local Slots = require "PhunInteriors/slots"
local Leash = require "PhunInteriors/leash"
local report = stubs.reporter()
local check = report.check

local sent = {}
Core.respond = function(player, command, args)
    table.insert(sent, {player = player, command = command, args = args})
end
local function lastTeleport(p)
    for i = #sent, 1, -1 do
        if sent[i].command == Core.commands.teleport and (not p or sent[i].player == p) then
            return sent[i].args
        end
    end
    return nil
end

local function player(name, x, y, z)
    local md = {}
    local at = {x = x or 0, y = y or 0, z = z or 0}
    return {
        at = at,
        getUsername = function() return name end,
        getModData = function() return md end,
        getX = function() return at.x end,
        getY = function() return at.y end,
        getZ = function() return at.z end
    }
end

local function claim(roomId, index, allowed)
    local b = Core.slotBounds(Core.rooms[roomId], index)
    table.insert(claims, {
        x = b.x1, y = b.y1, w = 1, h = 1,
        getOwner = function() return "owner" end,
        playerAllowed = function(_, p) return allowed and allowed[p:getUsername()] or false end
    })
end

local function holderOf(p)
    local occupancy = Transit.occupancyOf(p)
    return occupancy and occupancy.vehicleId
end

Core.registerRoom("arrival", {
    size = {w = 3, h = 4},
    spawn = {x = 1, y = 1},
    singleUse = true,
    locations = {[0] = {1000, 1000, 0}, [1] = {1100, 1000, 0}}
})

-- ---------------------------------------------------------------------------
-- Refusals, and a free slot.
-- ---------------------------------------------------------------------------
check("no player is refused", Transit.enterRoom(nil, "arrival"), false)
check("an unknown room is refused", Transit.enterRoom(player("x"), "nope"), false)

local a = player("a", 5, 5, 0)
local ok, where = Transit.enterRoom(a, "arrival", {reason = "test", share = true, returnTo = {7, 8, 0}})
check("a free slot is taken", ok, true)
check("the lowest one", where, "arrival#0")
check("under a key minted for the lease", Core.holderKind(holderOf(a)), "room")
check("not the admin key built from the player", holderOf(a) ~= Core.adminKey(a), true)
check("they are sent inside", lastTeleport(a) and lastTeleport(a).inside, true)
check("an exit is drawn by default", lastTeleport(a).noExit, nil)
check("the occupancy has no vehicle to look for", Transit.occupancyOf(a).noVehicle, true)
check("returnTo becomes the entrance a rescue reads", Transit.entranceOf(a) and Transit.entranceOf(a).x, 7)
check("and is where an exit goes", Transit.occupancyOf(a).returnTo.y, 8)
check("the lease is not given a vehicle position", Slots.find(holderOf(a)).lastKnownVehiclePos, nil)
check("and needs no battery", Slots.find(holderOf(a)).batteryKnown, 1)

-- ---------------------------------------------------------------------------
-- Idempotent: no second lease, no teleport.
-- ---------------------------------------------------------------------------
local leases = 0
for _ in pairs(Slots.store().assignments) do leases = leases + 1 end
sent = {}
check("a second call for the same room succeeds", Transit.enterRoom(a, "arrival", {share = true}), true)
check("without moving them", lastTeleport(a), nil)
local after = 0
for _ in pairs(Slots.store().assignments) do after = after + 1 end
check("or leasing another slot", after, leases)

-- Logged in inside, before our own playerSetup has rebuilt the occupancy.
local aHolder = holderOf(a)
Transit.setOccupancy(a, nil)
a.at.x, a.at.y = 1001, 1001
check("somebody standing in their lease is recovered", Transit.enterRoom(a, "arrival", {share = true}), true)
check("onto the same lease", holderOf(a), aHolder)
check("still without a teleport", lastTeleport(a), nil)

-- ---------------------------------------------------------------------------
-- Sharing when full.
-- ---------------------------------------------------------------------------
local b = player("b")
check("the second slot goes to the next person", select(2, Transit.enterRoom(b, "arrival", {share = true})),
    "arrival#1")
local c = player("c")
check("without share a full room refuses", Transit.enterRoom(c, "arrival"), false)
check("and leases nothing", Transit.occupancyOf(c), nil)

-- b's slot is claimed and c is not on it, so the only lease c may join is a's.
claim("arrival", 1, {})
local d = player("d")
check("with share a full room takes them anyway", Transit.enterRoom(c, "arrival", {share = true}), true)
check("into a's lease, the only one c may join", holderOf(c), holderOf(a))
claims = {}
check("and the next goes to the least occupied", Transit.enterRoom(d, "arrival", {share = true}), true)
check("which is b's", holderOf(d), holderOf(b))

-- ---------------------------------------------------------------------------
-- Released only when the last occupant leaves.
-- ---------------------------------------------------------------------------
local shared = holderOf(a)
check("the first of two out succeeds", Transit.sendTo(c, {x = 5, y = 5}, "test", true), true)
check("and the room is kept for the one still in it", Slots.find(shared) ~= nil, true)
check("the last one out succeeds", Transit.sendTo(a, {x = 5, y = 5}, "test", true), true)
check("and the lease goes with them", Slots.find(shared), nil)

-- ---------------------------------------------------------------------------
-- A lease handed back over the head of somebody logged off inside is
-- re-leased where they stand, not rescued out.
-- ---------------------------------------------------------------------------
local e = player("e", 1001, 1002, 0)
check("a holderless room re-leases in place on recover", Transit.recover(e), true)
check("on a fresh lease of the slot they are in", Transit.occupancyOf(e).index, 0)
check("of the holderless kind", Core.holderKind(holderOf(e)), "room")
Transit.sendTo(e, {x = 5, y = 5}, "test", true)

-- ---------------------------------------------------------------------------
-- A lease with nobody in it can be reclaimed like any other.
-- ---------------------------------------------------------------------------
stubs.worldAge = 0
local f = player("f")
Transit.enterRoom(f, "arrival", {share = true})
local fHolder = holderOf(f)
check("occupied, it is not reclaimable", Slots.isReclaimable(fHolder, Slots.find(fHolder)), false)
Transit.setOccupancy(f, nil)
stubs.worldAge = 10000 * 24
check("empty and old, it is", Slots.isReclaimable(fHolder, Slots.find(fHolder)), true)
check("and the reclaim picks it", (Slots.oldestReclaimable({arrival = 1})), fHolder)
Slots.release(fHolder, "test")

-- ---------------------------------------------------------------------------
-- Every slot claimed by somebody else: refused, even with share.
-- ---------------------------------------------------------------------------
Transit.setOccupancy(b, nil)
Transit.setOccupancy(d, nil)

for key in pairs(Slots.store().assignments) do Slots.release(key, "test") end
claim("arrival", 0, {})
claim("arrival", 1, {})
local g = player("g")
local refused, why = Transit.enterRoom(g, "arrival", {share = true})
check("every slot claimed refuses", refused, false)
check("with a reason", type(why), "string")
check("and nothing is left leased", Transit.occupancyOf(g), nil)
claims = {}

-- ---------------------------------------------------------------------------
-- exit = false: no way out but sendTo.
-- ---------------------------------------------------------------------------
local h = player("h")
check("an exitless entry succeeds", Transit.enterRoom(h, "arrival", {share = true, exit = false}), true)
check("the client is told to draw no exit", lastTeleport(h).noExit, true)
check("the leash contains rather than ejects", Leash.ejects(Transit.occupancyOf(h)), false)
check("where an ordinary tenant is ejected", Leash.ejects({}), true)
check("asking to leave is refused", Transit.requestLeave(h, "menu"), false)
check("and they are still inside", Transit.occupancyOf(h) ~= nil, true)
check("the lease remembers it for a recover", Slots.find(holderOf(h)).noExit, true)
local hHolder = holderOf(h)
Transit.setOccupancy(h, nil)
local slot = Slots.find(hHolder)
local bounds = Core.slotBounds(Core.rooms.arrival, slot.index)
h.at.x, h.at.y = bounds.x1 + 1, bounds.y1 + 1
Transit.recover(h)
check("which it does", Transit.occupancyOf(h).noExit, true)
check("sendTo still gets them out", Transit.sendTo(h, {x = 5, y = 5}, "picked", true), true)
check("and hands the room back", Slots.find(hHolder), nil)

-- ---------------------------------------------------------------------------
-- A shared room: a hub. Everybody lands in ONE lease however many slots the
-- room has, nothing reclaims it, no holder leases a slot of its own in it,
-- and any object bound to it leads in without taking a lease itself.
-- ---------------------------------------------------------------------------
Core.registerRoom("hub", {
    size = {w = 3, h = 4},
    spawn = {x = 1, y = 1},
    shared = true,
    locations = {[0] = {9000, 9000, 0}, [1] = {9100, 9000, 0}, [2] = {9200, 9000, 0}}
})
local hubA, hubB = player("hubA", 11, 12, 0), player("hubB", 13, 14, 0)
check("the first into a hub takes its first slot", select(2, Transit.enterRoom(hubA, "hub", {share = true})),
    "hub#0")
check("the second joins it rather than taking a free slot",
    select(2, Transit.enterRoom(hubB, "hub", {share = true})), "hub#0")
local hubHolder = holderOf(hubA)
check("under the same lease", holderOf(hubB), hubHolder)

Slots.age(hubHolder, 9999)
Transit.setOccupancy(hubA, nil)
Transit.setOccupancy(hubB, nil)
check("an empty, ancient hub is still not reclaimable",
    Slots.isReclaimable(hubHolder, Slots.find(hubHolder)), false)

-- A vehicle bound to a hub must not carve a private room out of it.
Core.registerVehicles({id = "t.hubvan", scripts = {"Base.HubVan"}, rooms = {"hub"}})
local hubVan = {
    getScript = function()
        return {
            getFullName = function() return "Base.HubVan" end,
            getName = function() return "HubVan" end
        }
    end
}
check("a vehicle is given no slot of a shared room", Slots.acquire("hub-van-uuid", hubVan), nil)

-- An object bound to the hub goes in through the shared lease.
Core.registerObjects({id = "t.hubobj", items = {"Base.HubToilet"}, rooms = {"hub"}})
local objMd = {}
local toilet = {
    getSprite = function()
        return {
            getName = function() return "hub_toilet_0" end,
            getProperties = function()
                return {
                    has = function(_, k) return k == "CustomItem" end,
                    get = function(_, k) return k == "CustomItem" and "Base.HubToilet" or nil end
                }
            end
        }
    end,
    getSquare = function() return nil end,
    getModData = function() return objMd end,
    hasModData = function() return false end
}
local hubC = player("hubC", 21, 22, 0)
check("entering a hub object succeeds", Transit.enterObject(hubC, toilet, {x = 20, y = 22, z = 0}), true)
check("into the one hub lease", holderOf(hubC), hubHolder)
check("coming back out where they stood, not on the object", Transit.occupancyOf(hubC).returnTo.x, 21)
check("and the object holds no lease of its own", Core.objectId(toilet, false), nil)

os.exit(report.finish("enterroom") == 0 and 0 or 1)
