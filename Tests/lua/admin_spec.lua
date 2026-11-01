local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
require "PhunInteriors/overrides"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Admin = require "PhunInteriors/admin"

Core.logLn = function() end
Core.debugLn = function() end

local report = stubs.reporter()
local check = report.check

-- ---------------------------------------------------------------------------
-- The admin actions the editor drives, and the slot payload it draws.
--
-- These are reachable from a console as well as from the window, and the
-- window is not testable at all -- so what can be checked here is everything
-- between the button and the registry.
-- ---------------------------------------------------------------------------

-- Mirrors SafeHouse.getSafehouseOverlapping as disassembled: a half open
-- rectangle, matching when x1 < x + w and x2 > x, and the same on y.
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

local function claimSlot(roomId, index, owner)
    local b = Core.slotBounds(Core.rooms[roomId], index)
    table.insert(claims, {
        x = b.x1, y = b.y1, w = 2, h = 2,
        getOwner = function() return owner end
    })
end

Core.registerRoom("a.room", {
    size = {w = 3, h = 3},
    locations = {[0] = {1000, 1000, 0}, [1] = {1100, 1000, 0}, [2] = {1200, 1000, 0}}
})

---------------------------------------------------------------------------
-- 1. The slot payload
---------------------------------------------------------------------------

stubs.worldAge = 0
Slots.acquire("veh-1", {getScript = function()
    return {getFullName = function() return "Base.X" end, getName = function() return "X" end}
end})
-- acquire resolves candidates from bindings, and there are none, so lease the
-- slot directly the way Transit's admin path does.
local assignment = Slots.store().assignments["veh-1"]
if not assignment then
    Slots.acquireIn("veh-1", "a.room", 0)
    assignment = Slots.store().assignments["veh-1"]
end
check("a lease exists to report on", assignment ~= nil, true)
assignment.lastUser = "sam"

-- Four world days later.
stubs.worldAge = 96

local detail = Admin.roomDetail(nil, "a.room")
local function slotAt(payload, index)
    for _, slot in ipairs(payload.slots) do
        if slot.index == index then
            return slot
        end
    end
end

local leased = slotAt(detail, 0)
check("the leased slot is reported leased", leased.state, "leased")
-- How long since anybody was in, which is what decides whether a slot is
-- worth resetting -- and it is the same measurement Slots.isReclaimable makes
-- against RoomProtectedDays, so the number on screen and the number that
-- decides a reclaim cannot disagree.
check("its idle age is in days", leased.idleDays, 4)
check("and it names who was last in", leased.lastUser, "sam")
-- Never the holder id: a 36 character UUID nobody can recognise, and 960 of
-- them would be most of the payload.
check("the holder id is not sent", leased.vehicleId, nil)

local free = slotAt(detail, 1)
check("a free slot is free", free.state, "free")
check("and has no idle age", free.idleDays, nil)
check("nor a last user", free.lastUser, nil)

---------------------------------------------------------------------------
-- 2. A safehouse claim is reported, and refuses a reset
---------------------------------------------------------------------------

check("nothing is claimed yet", slotAt(Admin.roomDetail(nil, "a.room"), 0).claimedBy, nil)

claimSlot("a.room", 0, "sam")
check("the claim is reported", slotAt(Admin.roomDetail(nil, "a.room"), 0).claimedBy, "sam")

-- The guard this spec exists for. Every other path already respects a claim --
-- Scrub.slot refuses one, isReclaimable refuses one, Slots.acquire skips one
-- -- and the admin reset was the hole: it would drop the lease and quarantine
-- the slot, so the owner loses the room they claimed and everything in it is
-- scrubbed the next time it is handed out.
local said = Admin.run("release", {room = "a.room", index = 0}, nil)
check("the reset is refused", string.find(said[1], "safehouse") ~= nil, true)
check("and names the owner", string.find(said[1], "sam") ~= nil, true)
check("the lease survived", Slots.find("veh-1") ~= nil, true)
check("and it is not in quarantine", #Slots.store().quarantine, 0)

-- With the claim gone it goes through, which is what proves the refusal was
-- the claim rather than anything else about the slot.
claims = {}
local done = Admin.run("release", {room = "a.room", index = 0}, nil)
check("without the claim it is reset", string.find(done[1], "released") ~= nil, true)
check("the lease is gone", Slots.find("veh-1"), nil)
check("and the slot is queued for a scrub", #Slots.store().quarantine, 1)

---------------------------------------------------------------------------
-- 3. Somebody standing in it still outranks everything
---------------------------------------------------------------------------

Slots.acquireIn("veh-2", "a.room", 2)
Core.occupants["sam"] = {room = "a.room", index = 2, vehicleId = "veh-2"}
local busy = Admin.run("release", {room = "a.room", index = 2}, nil)
check("an occupied slot is refused", string.find(busy[1], "inside") ~= nil, true)
check("its lease survived", Slots.find("veh-2") ~= nil, true)

-- free is the same act addressed by vehicle id, and used to skip both guards.
local busyFree = Admin.run("free", {vehicleId = "veh-2"}, nil)
check("free refuses an occupied slot too", string.find(busyFree[1], "inside") ~= nil, true)
check("and the lease survived free", Slots.find("veh-2") ~= nil, true)
Core.occupants["sam"] = nil

claimSlot("a.room", 2, "kim")
local claimedFree = Admin.run("free", {vehicleId = "veh-2"}, nil)
check("free refuses a claimed slot", string.find(claimedFree[1], "safehouse") ~= nil, true)
check("and names the owner", string.find(claimedFree[1], "kim") ~= nil, true)
check("the claimed lease survived free", Slots.find("veh-2") ~= nil, true)
claims = {}

local freed = Admin.run("free", {vehicleId = "veh-2"}, nil)
check("with nobody in it and no claim, free releases", string.find(freed[1], "released") ~= nil, true)
check("the freed lease is gone", Slots.find("veh-2"), nil)

---------------------------------------------------------------------------
-- 4. The room filter, shared with the window
---------------------------------------------------------------------------

-- Admin.roomMatches is what both the console list and the window's filter box
-- run, so "bar" finds the same rooms either way.
local row = {
    id = "phun.room.2x3_bar",
    label = "Bar",
    scripts = {"Base.Van_Charlemange_Beer"},
    items = {}
}
check("matches on a substring of the id", Admin.roomMatches(row, "2x3"), true)
check("matches on the label", Admin.roomMatches(row, "bar"), true)
check("matches on a script", Admin.roomMatches(row, "charlemange"), true)
check("does not match something absent", Admin.roomMatches(row, "tractor"), false)
check("an empty filter matches everything", Admin.roomMatches(row, ""), true)

---------------------------------------------------------------------------
-- Giving a room to another vehicle
---------------------------------------------------------------------------

Core.registerRoom("t.room", {
    size = {w = 3, h = 3},
    locations = {[0] = {3000, 1000, 0}, [1] = {3100, 1000, 0}}
})
Core.registerRoom("t.other", {
    size = {w = 3, h = 3},
    locations = {[0] = {3200, 1000, 0}}
})
Core.registerVehicles({scripts = {"Base.Trailer"}, rooms = {"t.room"}})
Core.registerVehicles({scripts = {"Base.Horsebox"}, rooms = {"t.other"}})

local function fakeVehicle(script, id)
    local modData = {[Core.consts.vehicleIdKey] = id}
    return {
        getScript = function()
            return {getFullName = function() return script end, getName = function() return script end}
        end,
        getModData = function() return modData end,
        getX = function() return 500 end,
        getY = function() return 600 end,
        getZ = function() return 0 end,
        getId = function() return 77 end,
        modData = modData
    }
end
local function standingBeside(vehicle)
    return {
        getUsername = function() return "tester" end,
        getVehicle = function() return vehicle end,
        getUseableVehicle = function() return nil end,
        getX = function() return 500 end,
        getY = function() return 600 end,
        getZ = function() return 0 end
    }
end

stubs.worldAge = 100
local lost = Slots.acquireIn("lost-trailer", "t.room", 1)
lost.lastUser = "sam"
lost.lastKnownVehiclePos = {x = 1, y = 2, z = 0}
lost.lastKnownHandle = 5
lost.fuelOwed = 9
lost.batteryKnown = 0.4
lost.fuelLast = 3
local slotsOf = function() return Slots.store().occupied["t.room"] end
local quarantined = #Slots.store().quarantine

local replacement = fakeVehicle("Base.Trailer", nil)
stubs.worldAge = 200
local moved = Admin.run("reassign", {room = "t.room", index = 1}, standingBeside(replacement))
local newId = replacement.modData[Core.consts.vehicleIdKey]
check("a new vehicle gets a lease id", newId ~= nil, true)
check("the lost vehicle no longer holds it", Slots.find("lost-trailer"), nil)
check("the new vehicle holds the same lease", Slots.find(newId), lost)
check("the slot names the new holder", slotsOf()["1"], newId)
check("the room keeps its slot", lost.index, 1)
check("the slot does not go through quarantine", #Slots.store().quarantine, quarantined)
check("exits go to the new vehicle", lost.lastKnownVehiclePos.x, 500)
check("not through the old handle", lost.lastKnownHandle, 77)
check("the old battery's debt is gone", lost.fuelOwed, 0)
check("and its reading", lost.batteryKnown, nil)
check("the room's tank level stays", lost.fuelLast, 3)
check("it counts as use", lost.lastSeen, 200)
check("who was last in stays", lost.lastUser, "sam")
check("the new vehicle is stamped as leased", replacement.modData[Core.consts.leasedKey], true)
check("a bound vehicle gets no warning", moved[1], "reassigned the room to that vehicle")

-- What the entry path actually does with it.
check("entering the new vehicle opens the same room", Slots.acquire(newId, replacement), lost)

local again = Admin.run("reassign", {vehicleId = newId}, standingBeside(replacement))
check("a vehicle cannot be given what it holds", again[1], "that vehicle already holds this room")

local busyHolder = fakeVehicle("Base.Trailer", "other-trailer")
Slots.acquireIn("other-trailer", "t.room", 0)
local both = Admin.run("reassign", {vehicleId = newId}, standingBeside(busyHolder))
check("a vehicle with its own room is refused", both[1], "that vehicle already holds t.room#0; reset that slot first")
check("and keeps it", Slots.find("other-trailer").index, 0)
check("and the room did not move", Slots.find(newId), lost)

local unbound = fakeVehicle("Base.Motorbike", "bike")
local noRooms = Admin.run("reassign", {vehicleId = newId}, standingBeside(unbound))
check("a vehicle bound to nothing is refused",
    noRooms[1], "that vehicle has no rooms bound to it, so it could never open this one")
check("and the room did not move to it", Slots.find(newId), lost)

Core.occupants["someone"] = {vehicleId = newId, room = "t.room", index = 1}
local inside = Admin.run("reassign", {vehicleId = newId}, standingBeside(fakeVehicle("Base.Trailer", "third")))
Core.occupants["someone"] = nil
check("a room somebody is in is refused", inside[1], "somebody is inside t.room#1; they have to come out first")
check("and stays put", Slots.find(newId), lost)

local horsebox = fakeVehicle("Base.Horsebox", "horsebox")
local across = Admin.run("reassign", {room = "t.room", index = 1}, standingBeside(horsebox))
check("another bound vehicle can take it, and is told",
    across[1], "reassigned the room to that vehicle, which is not normally bound to it, but will keep it")
check("and that vehicle opens this room rather than its own", Slots.acquire("horsebox", horsebox), lost)

Slots.acquireIn("admin:sam", "t.other", 0)
local adminLease = Admin.run("reassign", {vehicleId = "admin:sam"}, standingBeside(fakeVehicle("Base.Trailer", "fourth")))
check("only a vehicle's lease moves", adminLease[1], "t.other#0 is not held by a vehicle")
check("an unheld slot says so", Admin.run("reassign", {room = "t.other", index = 9}, standingBeside(horsebox))[1],
    "t.other#9 is not leased to anybody")
check("with nobody to stand anywhere it asks", Admin.run("reassign", {vehicleId = "horsebox"}, nil)[1],
    "stand beside the vehicle that should get this room, or sit in it")

---------------------------------------------------------------------------
-- Which vehicle a reassign is aimed at, and from where
---------------------------------------------------------------------------

Core.registerRoom("t.third", {
    size = {w = 3, h = 3},
    locations = {[0] = {3300, 1000, 0}}
})
local byId = {}
function getVehicleById(id)
    return byId[id]
end
local function resetThird()
    for _, id in ipairs({"src", "named", "seated", "far"}) do
        Slots.store().assignments[id] = nil
    end
    Slots.store().occupied["t.third"] = {}
    return Slots.acquireIn("src", "t.third", 0)
end

local seated = fakeVehicle("Base.Trailer", "seated")
local named = fakeVehicle("Base.Trailer", "named")
local farAway = fakeVehicle("Base.Trailer", "far")
farAway.getX = function() return 900 end
byId[77] = named
byId[78] = farAway

local third = resetThird()
Admin.run("reassign", {room = "t.third", index = 0, id = 77}, standingBeside(seated))
check("the vehicle the window named wins over the seat", Slots.find("named"), third)
check("and the seat gets nothing", Slots.find("seated"), nil)

third = resetThird()
local tooFar = Admin.run("reassign", {room = "t.third", index = 0, id = 78}, standingBeside(seated))
check("a named vehicle too far away is refused", tooFar[1],
    "stand beside the vehicle that should get this room, or sit in it")
check("and the room did not fall through to the seat", Slots.find("src"), third)

local stale = Admin.run("reassign", {room = "t.third", index = 0, id = 79}, standingBeside(seated))
check("a named vehicle that has gone is refused", stale[1],
    "stand beside the vehicle that should get this room, or sit in it")
check("and the room stays", Slots.find("src"), third)

local INSIDE = "you are inside a room; come out and stand beside the vehicle that should get it"
local visitor = standingBeside(seated)
visitor.getUsername = function() return "visitor" end
Core.occupants[Core.playerKey(visitor)] = {vehicleId = "admin:visitor", room = "t.other", index = 0}
local fromOccupancy = Admin.run("reassign", {room = "t.third", index = 0, id = 77}, visitor)
Core.occupants[Core.playerKey(visitor)] = nil
check("somebody on a visit cannot do it", fromOccupancy[1], INSIDE)
check("and the room stays", Slots.find("src"), third)

local walkedIn = standingBeside(seated)
walkedIn.getX = function() return 3301 end
walkedIn.getY = function() return 1001 end
check("nor somebody standing in a slot with no occupancy",
    Admin.run("reassign", {room = "t.third", index = 0, id = 77}, walkedIn)[1], INSIDE)
check("and the room stays", Slots.find("src"), third)

report.finish("admin")
