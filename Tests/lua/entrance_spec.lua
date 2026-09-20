-- The entrance position: where a tenant was standing when they went in.
--
-- The last of three return positions and the only one that outlives the lease,
-- which is the whole reason it exists. The other two describe the HOLDER -- a
-- vehicle's live position, or the one the tracker last banked on its lease --
-- and both vanish when the lease does. Before this, a tenant whose room was
-- reclaimed while they were logged off had nowhere to be put and Transit.leave
-- refused the exit outright, leaving them standing in the room.
--
-- Worth its own file for the same reason occupancy_spec is: the value is
-- durable state written on one path and read on another, months apart, and
-- every way it can be wrong is silent. In particular the recover case, which
-- is the one that would put somebody back INSIDE the room they are escaping.
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

local Transit = require "PhunInteriors/transit"
local report = stubs.reporter()
local check = report.check

local function player(name, x, y, z)
    local md = {}
    return {
        getUsername = function() return name end,
        getModData = function() return md end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z or 0 end,
        _md = md
    }
end

local bob = player("bob", 100, 200, 0)

-- ---------------------------------------------------------------------------
-- Storage, and the asymmetry between the two branches of setOccupancy.
-- ---------------------------------------------------------------------------

check("nothing stored to begin with", Transit.entranceOf(bob), nil)

Transit.setOccupancy(bob, {vehicleId = "v1", enteredFrom = {x = 10, y = 20, z = 0}})
local at = Transit.entranceOf(bob)
check("entering stores where they came from", at and at.x, 10)
check("and the y with it", at and at.y, 20)
check("and it is on the player, not in our own store",
    bob._md[Core.consts.entranceKey] ~= nil, true)

-- The case that would strand somebody in the room they are trying to leave.
-- Transit.recover sets an occupancy for a player who is standing INSIDE, so a
-- setOccupancy that read the player's position would overwrite the entrance
-- with the interior square. It must leave what is there alone.
Transit.setOccupancy(bob, {vehicleId = "v1", room = "r", index = 0})
at = Transit.entranceOf(bob)
check("an occupancy carrying no entrance leaves the stored one alone", at and at.x, 10)
check("and does not blank it", at ~= nil, true)

-- A second real entry is a new visit and does replace it.
Transit.setOccupancy(bob, {vehicleId = "v1", enteredFrom = {x = 30, y = 40, z = 1}})
at = Transit.entranceOf(bob)
check("a later entry replaces it", at and at.x, 30)
check("including the z", at and at.z, 1)

Transit.setOccupancy(bob, nil)
check("leaving clears it", Transit.entranceOf(bob), nil)
check("and clears it in the modData too",
    bob._md[Core.consts.entranceKey], nil)

-- Clearing when there was never one. Reachable through Transit.rescueStranded,
-- which routes its clear through setOccupancy precisely so the invariant
-- "an entrance exists only while an occupancy does" has one owner.
Transit.setOccupancy(bob, nil)
check("clearing an absent entrance is quiet", Transit.entranceOf(bob), nil)
check("and does not unbalance the occupancy count", Transit.anyoneInside(), false)

-- ---------------------------------------------------------------------------
-- Reading it back. It is durable state, so it has survived restarts and mod
-- versions and may be anything at all by the time it is read.
-- ---------------------------------------------------------------------------

local junk = player("junk", 0, 0, 0)
junk._md[Core.consts.entranceKey] = "somewhere"
check("a non-table record reads as nothing", Transit.entranceOf(junk), nil)

junk._md[Core.consts.entranceKey] = {y = 5}
check("a record missing its x reads as nothing", Transit.entranceOf(junk), nil)

junk._md[Core.consts.entranceKey] = {x = 1, y = 2}
local partial = Transit.entranceOf(junk)
check("a record with no z is read with z 0", partial and partial.z, 0)

-- Numbers that came back as strings, which is what a json round trip through
-- a third party tool does to them.
junk._md[Core.consts.entranceKey] = {x = "7", y = "8", z = "0"}
local coerced = Transit.entranceOf(junk)
check("stringified coordinates are coerced", coerced and coerced.x, 7)

-- ---------------------------------------------------------------------------
-- The fallback itself.
-- ---------------------------------------------------------------------------

local sue = player("sue", 0, 0, 0)
check("no entrance means no fallback", Transit.fallbackReturn(sue), nil)

Transit.setOccupancy(sue, {vehicleId = "v2", enteredFrom = {x = 55, y = 66, z = 0}})
local back = Transit.fallbackReturn(sue)
check("with one, it is offered", back and back.x, 55)
check("and it survives the lease being gone entirely",
    Transit.fallbackReturn(sue) ~= nil, true)

-- The staleness guard. A stored position is the one return that can name a
-- square this world does not have -- the map was dropped from the mod list, or
-- the grid moved under it -- and teleporting there moves the player for a
-- frame before the engine puts them back, which reads as the exit silently
-- doing nothing.
local worldMin, worldMax = 0, 1000
local realGetWorld = getWorld
function getWorld()
    return {
        getMetaGrid = function()
            return {
                isValidSquare = function(_, x, y)
                    return x >= worldMin and x <= worldMax and y >= worldMin and y <= worldMax
                end
            }
        end
    }
end

check("a square inside the world is still offered", Transit.fallbackReturn(sue) ~= nil, true)

Transit.setOccupancy(sue, nil)
Transit.setOccupancy(sue, {vehicleId = "v2", enteredFrom = {x = 99999, y = 66, z = 0}})
check("a square outside it is refused rather than teleported to",
    Transit.fallbackReturn(sue), nil)

getWorld = realGetWorld
Transit.setOccupancy(sue, nil)

-- ---------------------------------------------------------------------------
-- Saying it once. Transit.leave is reached from the leash every 250ms for as
-- long as a player stands on a square they cannot be taken off, so a line
-- logged per call is four a second for as long as they are stuck.
-- ---------------------------------------------------------------------------

local said = 0
local realLog = Core.logLn
Core.logLn = function()
    said = said + 1
end

local stuck = player("stuck", 0, 0, 0)
Transit.setOccupancy(stuck, {vehicleId = "v3", enteredFrom = {x = 12, y = 34, z = 0}})
local occ = Core.occupants["stuck"]
for _ = 1, 10 do
    Transit.fallbackReturn(stuck, occ)
end
Core.logLn = realLog
check("ten resolutions of one visit say it once", said, 1)

-- And with no occupancy to remember it on -- rescueStranded's case, which runs
-- once on login -- it still says it.
said = 0
Core.logLn = function()
    said = said + 1
end
Transit.fallbackReturn(stuck, nil)
Core.logLn = realLog
check("a one-shot caller still gets the line", said, 1)

Transit.setOccupancy(stuck, nil)

os.exit(report.finish("entrance") == 0 and 0 or 1)
