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
Core.occupants["sam"] = nil

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

report.finish("admin")
