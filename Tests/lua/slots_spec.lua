local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end
local Slots = require "PhunInteriors/slots"

local report = stubs.reporter()
local check = report.check
local function where(a) return a and (a.room .. "#" .. a.index) or "refused" end

-- Allocation resolves rooms from the vehicle itself, so a fake has to answer
-- getScript() and that is now all it has to answer. It used to need a trunk
-- probe too, because a room could state `requires` and every candidate was
-- tested on the way past; that field is gone.
local function vehicle(scriptName)
    return {
        getScript = function()
            return {
                getFullName = function() return scriptName end,
                getName = function() return scriptName end
            }
        end
    }
end

local vanA = vehicle("Base.A", true)
local vanB = vehicle("Base.B", true)
local vanZ = vehicle("Base.Z", true)

-- a.shared is the pool: two slots, reachable by both van scripts.
-- a.only is specialised: one slot, reachable only by Base.A.
Core.registerRoom("a.shared", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 0, 0}, [1] = {20, 0, 0}}
})
Core.registerRoom("a.only", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 100, 0}}
})
Core.registerVehicles({id = "a.both", rooms = {"a.shared"}, scripts = {"Base.A", "Base.B"}})
Core.registerVehicles({id = "a.justA", rooms = {"a.only"}, scripts = {"Base.A"}})

-- Two Base.A vehicles arrive first. Naive first fit would hand them both slots
-- out of the shared room and leave Base.B with nothing while a.only sat empty.
check("vanA takes the specialised room", where(Slots.acquire("v1", vanA)), "a.only#0")
check("vanA falls back to the shared pool", where(Slots.acquire("v2", vanA)), "a.shared#0")
check("vanB still has somewhere to go", where(Slots.acquire("v3", vanB)), "a.shared#1")
check("and now it really is full", (Slots.acquire("v4", vanB)), nil)
check("refusal names a translation key", select(2, Slots.acquire("v4", vanB)),
    "IGUI_PhunInteriors_NoFreeRoom")

-- An existing lease is handed straight back rather than reallocated.
check("existing lease is kept", where(Slots.acquire("v2", vanA)), "a.shared#0")

-- Releasing quarantines rather than freeing, and the slot comes back dirty.
Slots.release("v2", "test")
local reissued, _, dirty = Slots.acquire("v5", vanB)
check("quarantined slot is reissued", where(reissued), "a.shared#0")
check("and is flagged for a scrub", dirty, true)

-- A vehicle bound to nothing at all is refused with the right key.
check("unbound vehicle is refused", select(2, Slots.acquire("v6", vanZ)),
    "IGUI_PhunInteriors_NoRoomSet")

-- A room cannot refuse a holder any more, so the ONLY thing deciding which
-- room a vehicle gets is the specificity order and what is free.
--
-- This replaces a pair of checks built on `requires`: a room demanding a trunk
-- was skipped for a vehicle without one, and a vehicle whose every room
-- refused it got the room's own message rather than "full". Both went with the
-- field. What is worth keeping from them is the ordering they were expressed
-- in, so the same two rooms are here and the specialised one still drains
-- first for everybody.
Core.registerRoom("a.special", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 200, 0}}
})
Core.registerRoom("a.opentop", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 300, 0}}
})
-- Two bindings so a.opentop is reachable by two scripts and therefore the more
-- general of the pair; a.special is drained first.
Core.registerVehicles({id = "a.picky", rooms = {"a.special", "a.opentop"}, scripts = {"Base.P"}})
Core.registerVehicles({id = "a.picky2", rooms = {"a.opentop"}, scripts = {"Base.Q"}})
check("the specialised room drains first",
    where(Slots.acquire("v7", vehicle("Base.P"))), "a.special#0")
check("and the next vehicle falls through to the general one",
    where(Slots.acquire("v8", vehicle("Base.P"))), "a.opentop#0")

-- With nothing able to refuse, a vehicle whose only room is taken gets the
-- full-pool message. There used to be a separate "every room refused you"
-- branch here carrying the room's own reason; it is unreachable now and gone.
Core.registerRoom("a.onlyone", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 400, 0}}
})
Core.registerVehicles({id = "a.solo", rooms = {"a.onlyone"}, scripts = {"Base.R"}})
check("the one slot goes to the first asker",
    where(Slots.acquire("v9", vehicle("Base.R"))), "a.onlyone#0")
check("and the second is told it is full",
    select(2, Slots.acquire("v9b", vehicle("Base.R"))), "IGUI_PhunInteriors_NoFreeRoom")

-- A lease pointing at a slot that no longer exists is let go, not honoured.
-- Re-registering the room with fewer locations is the realistic way that
-- happens.
check("lease exists before", where(Slots.find("v3")), "a.shared#1")
Core.registerRoom("a.shared", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 0, 0}}
})
check("slot 1 is gone from the room", Core.slotOrigin(Core.rooms["a.shared"], 1), nil)

-- With every remaining slot taken there is nowhere to rehome to, and the
-- refusal is the honest answer -- but the dangling lease must still be gone.
check("full pool refuses", (Slots.acquire("v3", vanB)), nil)
check("stale lease was let go", Slots.find("v3"), nil)

-- Free one and the same vehicle is rehomed rather than left stranded.
Slots.release("v5", "test")
check("rehomed into a real slot", where(Slots.acquire("v3", vanB)), "a.shared#0")

-- ---------------------------------------------------------------------------
-- Slots.acquireIn -- the admin tool's lease, which ignores the bindings.
--
-- Everything above is about entitlement. This is about pointing at a room and
-- being put in it, so none of the ordering applies and the only rules left are
-- that a slot has one holder and that a quarantined one is reissued dirty.
-- ---------------------------------------------------------------------------

Core.registerRoom("a.admin", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 500, 0}, [1] = {20, 500, 0}, [2] = {40, 500, 0}}
})

check("an unbound room is still leasable by name",
    where(Slots.acquireIn("admin:bob", "a.admin")), "a.admin#0")
check("asking again renews rather than taking another",
    where(Slots.acquireIn("admin:bob", "a.admin")), "a.admin#0")
check("a named slot is honoured",
    where(Slots.acquireIn("admin:bob", "a.admin", 2)), "a.admin#2")
check("and the one it left went back", Core.tools.isEmpty(Slots.store().occupied["a.admin"]["0"] or {}), true)

-- One holder per slot, whoever is asking.
check("somebody else's lease is not taken",
    (Slots.acquireIn("admin:sue", "a.admin", 2)), nil)
check("and it says who has it",
    string.find(select(2, Slots.acquireIn("admin:sue", "a.admin", 2)), "admin:bob") ~= nil, true)

check("a slot that does not exist is refused",
    (Slots.acquireIn("admin:sue", "a.admin", 99)), nil)
check("an unregistered room is refused",
    (Slots.acquireIn("admin:sue", "nobody.room")), nil)

-- Release -> re-enter is the scrub test loop, so the reissue must come back
-- flagged dirty. Without that the slot is handed straight back as if clean and
-- the scrub never runs.
-- Counted as a delta: earlier releases in this file left their own entries in
-- the queue, and an absolute count here would be measuring those.
local queued = #Slots.store().quarantine
Slots.release("admin:bob", "test")
check("release quarantines it", #Slots.store().quarantine - queued, 1)
local reissued, _, dirty = Slots.acquireIn("admin:bob", "a.admin", 2)
check("the same slot comes back", where(reissued), "a.admin#2")
check("flagged for a scrub", dirty, true)
check("and is out of the queue", #Slots.store().quarantine - queued, 0)

-- Releasing a lease that has a stored vehicle position.
--
-- This is the path that threw in game: release hands back the mass it added,
-- and the call it used for that -- Weight.queue -- had been deleted three
-- commits earlier. Every check above went through release and none of them
-- caught it, because none set lastKnownVehiclePos, so the branch was never
-- entered. The admin lease is the case that actually failed: press Enter on a
-- second room and acquireIn releases the first, which by then has a position.
local held = Slots.acquireIn("admin:kim", "a.admin", 0)
held.lastKnownVehiclePos = {x = 100, y = 200, z = 0}
check("an admin lease with a stored position releases",
    Slots.release("admin:kim", "test"), true)

-- And the vehicle case, which takes the other branch: it is not an admin key,
-- so it sweeps for the vehicle, finds nothing in the stubbed empty world, and
-- leaves the delta for the next lease to compose over.
local leased = Slots.acquireIn("v9", "a.admin", 1)
leased.lastKnownVehiclePos = {x = 100, y = 200, z = 0}
check("a vehicle lease with a stored position releases",
    Slots.release("v9", "test"), true)

-- ---------------------------------------------------------------------------
-- Reclaiming. Nothing expires on a clock: a lease is only taken when a vehicle
-- needs a room, every room it could have is full, and this one has gone unused
-- for RoomProtectedDays.
-- ---------------------------------------------------------------------------

local Transit = require "PhunInteriors/transit"
local DAY = 24
-- Well clear of every lease stamped above, at hour zero, in rooms no vehicle
-- below can reach -- so none of them is ever a candidate here.
local function at(days)
    stubs.worldAge = 1000 * DAY + days * DAY
end
local function queued(roomId, index)
    for _, entry in ipairs(Slots.store().quarantine) do
        if entry.room == roomId and entry.index == index then
            return true
        end
    end
    return false
end

Core.settings.RoomProtectedDays = 14
Core.registerRoom("c.general", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 600, 0}, [1] = {20, 600, 0}}
})
Core.registerRoom("c.special", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 700, 0}}
})
Core.registerVehicles({id = "c.both", rooms = {"c.general"}, scripts = {"Base.G", "Base.H"}})
Core.registerVehicles({id = "c.justG", rooms = {"c.special"}, scripts = {"Base.G"}})
local vanG, vanH = vehicle("Base.G", true), vehicle("Base.H", true)

at(0)
check("g1 takes the specialised room", where(Slots.acquire("g1", vanG)), "c.special#0")
check("g2 takes a general one", where(Slots.acquire("g2", vanG)), "c.general#0")
check("h1 takes the last", where(Slots.acquire("h1", vanH)), "c.general#1")

at(10)
Slots.touch("g2")
check("nobody away long enough, so it is simply full", (Slots.acquire("h2", vanH)), nil)
check("and says so", select(2, Slots.acquire("h2", vanH)), "IGUI_PhunInteriors_NoFreeRoom")
check("with nobody's room taken", where(Slots.find("h1")), "c.general#1")

at(20)
local taken, _, takenDirty = Slots.acquire("h2", vanH)
check("past the protection, the longest unused room is taken", where(taken), "c.general#1")
check("handed over for a scrub", takenDirty, true)
check("from the vehicle that held it", Slots.find("h1"), nil)
check("and not left behind in the queue", queued("c.general", 1), false)
check("a room used more recently is left alone", where(Slots.find("g2")), "c.general#0")

-- g1 has not been used for twenty days, but somebody is standing in it.
local tenantData = {}
local tenant = {
    getUsername = function() return "tenant" end,
    -- setOccupancy maintains the durable entrance position here
    getModData = function() return tenantData end
}
Transit.setOccupancy(tenant, {vehicleId = "g1", room = "c.special", index = 0})
check("a room somebody is inside is never taken", (Slots.acquire("g3", vanG)), nil)
check("however long it has gone unrenewed", where(Slots.find("g1")), "c.special#0")
Transit.setOccupancy(tenant, nil)
check("and once they are out, it can be", where(Slots.acquire("g3", vanG)), "c.special#0")

-- g2 is thirty days unused in c.general; g3 and h2 are twenty. c.special comes
-- first in a G's candidate order, and that is not what decides it.
at(40)
check("the longest unused goes, whichever room it is in",
    where(Slots.acquire("g4", vanG)), "c.general#0")
check("so the specialised room is untouched", where(Slots.find("g3")), "c.special#0")

Slots.release("g4", "test")
check("a free slot is spent before anybody's room is taken",
    where(Slots.acquire("h3", vanH)), "c.general#0")
check("even with a room past its protection", where(Slots.find("h2")), "c.general#1")

Core.settings.RoomProtectedDays = 0
check("with no protection, a full pool takes a room straight away",
    where(Slots.acquire("h4", vanH)), "c.general#1")
check("still the longest unused one", where(Slots.find("h3")), "c.general#0")

-- A tie, which adoptBaseline makes routine. pairs() order is no tiebreak.
at(80)
Slots.touch("h3")
Slots.touch("h4")
at(100)
check("a tie breaks on the slot", where(Slots.acquire("h5", vanH)), "c.general#0")
check("the other is kept", where(Slots.find("h4")), "c.general#1")
-- The other end of the range, which is how an admin says NEVER. There is no
-- separate "allow reclaiming" tick, so the top of the slider has to actually
-- hold: a room that has sat unused for years is still not taken, and the
-- vehicle is refused instead. Deliberately not a special-cased sentinel --
-- just a number so large the comparison cannot come true inside a save -- so
-- what is checked is the arithmetic rather than an `if`.
Core.settings.RoomProtectedDays = 99999999
at(100000)
check("at the top of the range nothing is ever reclaimable",
    (Slots.oldestReclaimable({["c.general"] = 1})), nil)
check("and a vehicle needing a room is refused rather than given somebody else's",
    select(2, Slots.acquire("h6", vanH)), "IGUI_PhunInteriors_NoFreeRoom")
check("every existing lease survived", where(Slots.find("h5")), "c.general#0")

Core.settings.RoomProtectedDays = 14
at(100)

-- h5 was leased just now; h4 was last used on day 80, which is past fourteen
-- days, so renew it to leave c.general with nothing past its protection.
Slots.touch("h4")
check("nothing past its protection means nothing to reclaim",
    (Slots.oldestReclaimable({["c.general"] = 1})), nil)

-- ---------------------------------------------------------------------------
-- Safehouse claims. A claimed room is never scrubbed, never reclaimed and
-- never handed to a vehicle that does not already hold it.
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
-- A claim relative to a slot's north-west corner.
local function claim(roomId, index, dx, dy, w, h)
    local b = Core.slotBounds(Core.rooms[roomId], index)
    table.insert(claims, {
        x = b.x1 + dx, y = b.y1 + dy, w = w, h = h,
        getOwner = function() return "sam" end
    })
end

Core.registerRoom("s.room", {
    size = {w = 3, h = 4},
    locations = {[0] = {0, 900, 0}, [1] = {40, 900, 0}, [2] = {80, 900, 0}}
})
Core.registerVehicles({id = "s.vans", rooms = {"s.room"}, scripts = {"Base.S"}})
local vanS = vehicle("Base.S", true)

-- The edges, which is where the half open rectangle bites. The footprint is
-- 3 wide, so its last column is dx = 2 and dx = 3 is the square beyond it.
claim("s.room", 0, 3, 0, 5, 5)
check("a claim that ends at the footprint's edge is not on it", Slots.safehouseOn("s.room", 0), nil)
claims = {}
claim("s.room", 0, 2, 3, 1, 1)
check("a claim over only the far corner square is", Slots.safehouseOn("s.room", 0) ~= nil, true)
claims = {}
claim("s.room", 0, -5, -5, 5, 5)
check("one that ends just north-west of it is not", Slots.safehouseOn("s.room", 0), nil)
claims = {}

claim("s.room", 0, 0, 0, 3, 4)
check("a claimed free slot is passed over", where(Slots.acquire("s1", vanS)), "s.room#1")
check("the next vehicle takes the last unclaimed one", where(Slots.acquire("s2", vanS)), "s.room#2")

Slots.release("s2", "test")
claim("s.room", 2, 0, 0, 3, 4)
check("a claimed quarantined slot is passed over too", (Slots.acquire("s3", vanS)), nil)
check("so the admin tool finds nothing free either", (Slots.acquireIn("admin:pat", "s.room")), nil)

-- s1's own room is claimed and long past its protection.
at(300)
claim("s.room", 1, 1, 1, 1, 1)
check("a claimed lease is not reclaimable", Slots.isReclaimable("s1", Slots.find("s1")), false)
check("so a full pool refuses rather than take it", (Slots.acquire("s3", vanS)), nil)
check("and its holder keeps it", where(Slots.find("s1")), "s.room#1")
check("the admin list says whose it is", (function()
    for _, lease in ipairs(Slots.summary().leases) do
        if lease.vehicleId == "s1" then
            return lease.claimedBy
        end
    end
end)(), "sam")

local Scrub = require "PhunInteriors/scrub"
local scrubbed, why = Scrub.slot("s.room", 2)
check("a claimed slot is never scrubbed", scrubbed, false)
check("and the refusal names the owner", string.find(tostring(why), "safehouse by sam", 1, true) ~= nil, true)

-- Claims lifted, in the order allocation spends them: the free slot, then the
-- quarantined one, and only then somebody's long unused room.
claims = {}
check("once the claims go, the free slot is spent first", where(Slots.acquire("s3", vanS)), "s.room#0")
check("then the quarantined one", where(Slots.acquire("s4", vanS)), "s.room#2")
check("and then the room that was claimed is reclaimable again", where(Slots.acquire("s5", vanS)), "s.room#1")
check("from the vehicle that held it", Slots.find("s1"), nil)

-- ---------------------------------------------------------------------------
-- Trespass. A claim protects the room from being taken away, and separately
-- decides who may walk into it.
--
-- These are two different questions and the code keeps them apart:
-- Slots.safehouseOn asks "is there a claim", which is what stops a scrub, a
-- reclaim and a reset; Slots.trespassOn asks "may this person go in", which
-- is what the entry paths ask.
--
-- It exists because nothing in the engine asks it for us. The whole
-- enforcement surface for a claimed square is BaseVehicle.isExitBlocked2 --
-- getting out of a seat onto one -- so a teleport lands on it unopposed.
-- ---------------------------------------------------------------------------

local function playerNamed(name, capability)
    return {
        getUsername = function() return name end,
        _capability = capability
    }
end

-- Mirrors playerAllowed off the bytecode: a member, the owner, or a role
-- carrying CanGoInsideSafehouses.
local function claimOwnedBy(roomId, index, owner, members)
    local b = Core.slotBounds(Core.rooms[roomId], index)
    local house
    house = {
        x = b.x1, y = b.y1, w = 2, h = 2,
        getOwner = function() return owner end,
        playerAllowed = function(_, player)
            if player:getUsername() == owner then
                return true
            end
            for _, m in ipairs(members or {}) do
                if m == player:getUsername() then
                    return true
                end
            end
            return player._capability == true
        end
    }
    table.insert(claims, house)
    return house
end

Core.registerRoom("t.claimed", {size = {w = 2, h = 2}, locations = {[0] = {0, 5000, 0}}})
check("nobody is trespassing on an unclaimed room",
    Slots.trespassOn("t.claimed", 0, playerNamed("bob")), nil)

claimOwnedBy("t.claimed", 0, "alice", {"carol"})
check("the owner may go in", Slots.trespassOn("t.claimed", 0, playerNamed("alice")), nil)
check("a member may go in", Slots.trespassOn("t.claimed", 0, playerNamed("carol")), nil)
check("a stranger may not",
    Slots.trespassOn("t.claimed", 0, playerNamed("bob")) ~= nil, true)
check("and the refusal names the owner",
    Slots.trespassOn("t.claimed", 0, playerNamed("bob")):getOwner(), "alice")
-- No exemption of ours: vanilla's own role capability is what lets an admin
-- in, which is the same rule governing every other safehouse in the world.
check("a role with the capability may go in",
    Slots.trespassOn("t.claimed", 0, playerNamed("dave", true)), nil)
claims = {}

os.exit(report.finish("slots") == 0 and 0 or 1)
