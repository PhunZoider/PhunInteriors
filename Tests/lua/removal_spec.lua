-- Releasing the room of a vehicle that has been removed from the world.
--
-- The difficulty is that "removed" cannot be read off a vehicle:
-- isRemovedFromWorld() is just as true of one that merely unloaded. So what is
-- worth proving is that a room is released on the change and never on the
-- state, and never out from under somebody standing in it.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end

local clock = 0
function getTimestampMs() return clock end

local byHandle = {}
function getVehicleById(handle) return byHandle[handle] end

-- The blowtorch action. Vanilla's complete() drops scrap and then calls
-- permanentlyRemove(); only the last half matters here. `refuse` stands in for
-- every way it can finish without removing anything.
ISRemoveBurntVehicle = {}
function ISRemoveBurntVehicle:complete()
    if self.refuse then
        return false
    end
    self.vehicle.removed = true
    return true
end
local function scrap(vehicle, refuse)
    local action = setmetatable({vehicle = vehicle, refuse = refuse}, {__index = ISRemoveBurntVehicle})
    return action:complete()
end

local Slots = require "PhunInteriors/slots"
local Transit = require "PhunInteriors/transit"

-- notePosition reads a real vehicle and settles its battery, neither of which a
-- table can stand in for. Counting the calls is all that is asked of it here.
local noted = 0
Transit.notePosition = function()
    noted = noted + 1
    return true
end
local refuseLeave = false
Transit.leave = function(player)
    if refuseLeave then
        return false, "their vehicle is moving and every seat is taken"
    end
    Transit.setOccupancy(player, nil)
    return true
end
local online = {}
Core.tools.getPlayerByUsername = function(name) return online[name] end

local Removal = require "PhunInteriors/removal"
Removal.install()

local report = stubs.reporter()
local check = report.check

local locations = {}
for i = 0, 11 do
    locations[i] = {i * 40, 0, 0}
end
Core.registerRoom("r.van", {size = {w = 3, h = 4}, locations = locations})
Core.registerVehicles({id = "r.van", scripts = {"Base.Van"}, rooms = {"r.van"}})

local lastHandle = 0
local function van(uuid)
    lastHandle = lastHandle + 1
    local v = {removed = false, handle = lastHandle}
    local md = {[Core.consts.vehicleIdKey] = uuid}
    function v.getModData() return md end
    function v.isRemovedFromWorld() return v.removed end
    function v.getId() return v.handle end
    function v.getScript()
        return {getFullName = function() return "Base.Van" end, getName = function() return "Base.Van" end}
    end
    function v.getPartByIndex()
        return {getItemContainer = function() return {} end, getContainerCapacity = function() return 30 end}
    end
    byHandle[v.handle] = v
    assert(Slots.acquire(uuid, v), "no room for " .. uuid)
    return v
end
local function leased(uuid) return Slots.find(uuid) ~= nil end
local function person(name, access)
    local md = {}
    return {
        getUsername = function() return name end,
        getAccessLevel = function() return access end,
        -- setOccupancy maintains the durable entrance position here
        getModData = function() return md end
    }
end
local function moveIn(player, uuid)
    Transit.setOccupancy(player, {vehicleId = uuid, room = "r.van", index = Slots.find(uuid).index})
end

-- The blowtorch.
local wreck = van("wreck")
check("scrapping hands back what vanilla returned", scrap(wreck), true)
check("scrapping a leased wreck releases its room", leased("wreck"), false)
check("having banked its position first", noted, 1)

local halfDone = van("halfdone")
scrap(halfDone, true)
check("a scrap that removes nothing keeps the room", leased("halfdone"), true)

-- The case this whole file is shaped around. An unloaded vehicle already
-- reads as removed, so reading the state after the fact would release it.
local parked = van("parked")
parked.removed = true
scrap(parked)
check("a vehicle already out of the world is not a removal", leased("parked"), true)

-- Tenants.
local bob, sue = person("bob"), person("sue")
local lived = van("lived")
online.bob = bob
moveIn(bob, "lived")
scrap(lived)
check("a tenant is put out first", Core.occupants.bob, nil)
check("and then the room is released", leased("lived"), false)

local away = van("away")
moveIn(sue, "away")
scrap(away)
check("a tenant who is offline keeps the room", leased("away"), true)
check("and stays inside", Core.occupants.sue ~= nil, true)
Transit.setOccupancy(sue, nil)

local busy = van("busy")
online.sue = sue
moveIn(sue, "busy")
refuseLeave = true
scrap(busy)
refuseLeave = false
check("a tenant who cannot be put out keeps the room", leased("busy"), true)
Transit.setOccupancy(sue, nil)

-- The admin cheat, which the server only hears about in advance.
local admin = person("admin")
local cheat = van("cheat")
Removal.tick()
check("a tick with nothing watched is harmless", leased("cheat"), true)
check("a warned removal is watched", Removal.watch(admin, cheat:getId()), true)
Removal.tick()
check("nothing is released before it happens", leased("cheat"), true)
cheat.removed = true
Removal.tick()
check("and it is released once it does", leased("cheat"), false)

local spared = van("spared")
Removal.watch(admin, spared:getId())
clock = clock + 6000
Removal.tick()
spared.removed = true -- an unload, long after the warning lapsed
Removal.tick()
check("a watch that lapsed releases nothing later", leased("spared"), true)

check("a handle that resolves to nothing is not watched", Removal.watch(admin, 9999), false)

local wasLocal = Core.isLocal
Core.isLocal = false
local target = van("target")
check("a notice from a non-admin is ignored", Removal.watch(person("eve", "None"), target:getId()), false)
Core.isLocal = wasLocal

os.exit(report.finish("removal") == 0 and 0 or 1)
