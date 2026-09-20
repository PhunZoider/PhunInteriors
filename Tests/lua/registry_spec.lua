local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/bounds"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end

local report = stubs.reporter()
local check = report.check

-- A vehicle is only ever asked for its script, so that is all a fake needs.
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

-- 1. positional triples, keyed by index, non-uniform spacing
Core.registerRoom("t.list", {
    size = {w = 5, h = 15}, spawn = {x = 2, y = 2}, exits = {{x = 2, y = 0}},
    locations = {
        [0] = {22538, 11779, 0},
        [1] = {22562, 11779, 0},
        [2] = {22900, 11779, 0}
    }
})
local list = Core.rooms["t.list"]
check("list slot count", #list.indices, 3)
check("list slot 0", Core.slotOrigin(list, 0).x, 22538)
check("list slot 2", Core.slotOrigin(list, 2).x, 22900)
check("missing slot is nil", Core.slotOrigin(list, 9), nil)
check("bounds of missing slot", Core.slotBounds(list, 9), nil)

-- 2. named fields mean the same as positional
Core.registerRoom("t.named", {
    size = {w = 2, h = 2},
    locations = {[0] = {x = 10, y = 20, z = 0}, [1] = {x = 40, y = 20}}
})
check("named x", Core.slotOrigin(Core.rooms["t.named"], 0).x, 10)
check("named y", Core.slotOrigin(Core.rooms["t.named"], 0).y, 20)
check("z defaults to 0", Core.slotOrigin(Core.rooms["t.named"], 1).z, 0)

-- 3. THE GAP. Deleting a location must not delete every location after it.
-- The old walk counted up from 0 until it hit a nil, so a hole at 2 silently
-- took 3 and 4 with it and the room quietly shrank.
Core.registerRoom("t.gap", {
    size = {w = 2, h = 2},
    locations = {
        [0] = {100, 100, 0},
        [1] = {200, 100, 0},
        -- [2] deleted: this room was built wrong and was removed by hand
        [3] = {400, 100, 0},
        [4] = {500, 100, 0}
    }
})
local gap = Core.rooms["t.gap"]
check("gap keeps every surviving location", #gap.indices, 4)
check("gap survives past the hole", Core.slotOrigin(gap, 4).x, 500)
check("the hole itself is nil", Core.slotOrigin(gap, 2), nil)
check("indices are sorted", table.concat(gap.indices, ","), "0,1,3,4")
check("count is the highest index", gap.count, 4)

-- 4. slotAt finds an arbitrarily placed room, and only inside it
check("slotAt inside slot 2", select(2, Core.slotAt(22902, 11785, 0)), 2)
check("slotAt room id", (Core.slotAt(22902, 11785, 0)), "t.list")
check("slotAt on the roof", select(2, Core.slotAt(22902, 11785, 1)), 2)
check("slotAt above the roof", Core.slotAt(22902, 11785, 2), nil)
check("slotAt in the gap", Core.slotAt(22700, 11785, 0), nil)
check("slotAt far away", Core.slotAt(1, 1, 0), nil)
-- a room straddling a bucket boundary (64) must be found from both halves
Core.registerRoom("t.straddle", {size = {w = 10, h = 2}, locations = {[0] = {60, 300, 0}}})
check("straddle west of boundary", (Core.slotAt(61, 300, 0)), "t.straddle")
check("straddle east of boundary", (Core.slotAt(68, 300, 0)), "t.straddle")

-- 5. bindings resolve by script name, and are UNIONED across bindings rather
-- than replaced -- that is what lets a second author add rooms for a script
-- somebody else's binding already covers.
Core.registerRoom("t.roomA", {size = {w = 2, h = 2}, locations = {[0] = {0, 1000, 0}}})
Core.registerRoom("t.roomB", {size = {w = 2, h = 2}, locations = {[0] = {0, 1100, 0}}})
Core.registerRoom("t.roomC", {size = {w = 2, h = 2}, locations = {[0] = {0, 1200, 0}}})

Core.registerVehicles({id = "t.shared", rooms = {"t.roomA"}, scripts = {"Base.VanA", "Base.VanB"}})
Core.registerVehicles({id = "t.onlyA", rooms = {"t.roomB"}, scripts = {"Base.VanA"}})
Core.registerVehicles({id = "t.onlyC", rooms = {"t.roomC"}, scripts = {"Base.VanC"}})

local forA = Core.roomsForVehicle(vehicle("Base.VanA"))
check("vanA draws from both bindings", #forA, 2)
-- roomB is named by one binding, roomA by one too -- but roomA is reachable
-- from VanB as well, so it is the more general and must come second.
check("vanA most specialised first", forA[1], "t.roomB")
check("vanA general second", forA[2], "t.roomA")
check("vanB gets the shared room", Core.roomsForVehicle(vehicle("Base.VanB"))[1], "t.roomA")
check("vanB has no other option", #Core.roomsForVehicle(vehicle("Base.VanB")), 1)
check("unknown script gets nothing", #Core.roomsForVehicle(vehicle("Base.Nope")), 0)
check("has rooms", Core.vehicleHasRooms(vehicle("Base.VanA")), true)
check("has no rooms", Core.vehicleHasRooms(vehicle("Base.Nope")), false)

-- 6. a matcher ADDS to the script list rather than replacing it
Core.registerRoom("t.matched", {size = {w = 2, h = 2}, locations = {[0] = {0, 1250, 0}}})
Core.registerVehicles({
    id = "t.matcher", rooms = {"t.matched"},
    match = function(v) return tostring(v:getScript():getName()):find("^Step") ~= nil end
})
check("a matched vehicle gets the room", Core.roomsForVehicle(vehicle("StepVanMail"))[1], "t.matched")
check("an unmatched one does not", #Core.roomsForVehicle(vehicle("Base.Sedan")), 0)
-- VanA is covered by two script bindings; the matcher must not add to it
check("matcher did not take vanA", #Core.roomsForVehicle(vehicle("Base.VanA")), 2)

-- 7. a binding naming a room nobody registered is ignored, not fatal, but is
-- reported -- that is the whole reason rooms register in a phase of their own
Core.registerVehicles({id = "t.vanD", rooms = {"t.missing", "t.roomC"}, scripts = {"Base.VanD"}})
local vanD = vehicle("Base.VanD")
check("missing room skipped", #Core.roomsForVehicle(vanD), 1)
check("present room kept", Core.roomsForVehicle(vanD)[1], "t.roomC")
check("missing room is reported", Core.unresolvedFor(vanD)[1], "t.missing")
check("and only that one", #Core.unresolvedFor(vanD), 1)
check("a vehicle missing nothing says nothing", Core.unresolvedFor(vehicle("Base.VanB")), nil)

-- 7b. a binding declared before its room exists still resolves, so the phase
-- order is a convention rather than something correctness depends on
Core.registerVehicles({id = "t.vanE", rooms = {"t.late"}, scripts = {"Base.VanE"}})
local vanE = vehicle("Base.VanE")
check("unresolved before the room arrives", #Core.roomsForVehicle(vanE), 0)
check("reported as missing meanwhile", Core.unresolvedFor(vanE)[1], "t.late")
Core.registerRoom("t.late", {size = {w = 2, h = 2}, locations = {[0] = {0, 1400, 0}}})
check("resolves once the room registers", Core.roomsForVehicle(vanE)[1], "t.late")
check("and stops being reported", Core.unresolvedFor(vanE), nil)

-- 8. specificity is how many bindings name a room, and a late binding
-- re-orders an existing vehicle's candidates
Core.registerRoom("t.roomD", {size = {w = 2, h = 2}, locations = {[0] = {0, 1300, 0}}})
Core.registerVehicles({id = "t.vanCd", rooms = {"t.roomD"}, scripts = {"Base.VanC"}})
local vanC = vehicle("Base.VanC")
check("late room appears", #Core.roomsForVehicle(vanC), 2)
check("roomD named by one binding", Core.servingCount("t.roomD"), 1)
check("roomC named by two", Core.servingCount("t.roomC"), 2)
check("specialised room ordered first", Core.roomsForVehicle(vanC)[1], "t.roomD")
check("general room second", Core.roomsForVehicle(vanC)[2], "t.roomC")

-- 8b. priority separates equally specialised rooms, and specificity still
-- beats it -- a preference must never be able to reintroduce starvation.
Core.registerRoom("t.zzz", {size = {w = 2, h = 2}, locations = {[0] = {0, 1500, 0}}, priority = 0})
Core.registerRoom("t.aaa", {size = {w = 2, h = 2}, locations = {[0] = {0, 1600, 0}}, priority = 5})
Core.registerVehicles({id = "t.vanF", rooms = {"t.zzz", "t.aaa"}, scripts = {"Base.VanF"}})
local vanF = vehicle("Base.VanF")
check("priority beats the id tiebreak", Core.roomsForVehicle(vanF)[1], "t.zzz")
check("worse priority second", Core.roomsForVehicle(vanF)[2], "t.aaa")

-- t.aaa is now named by two bindings, so it is less specialised than t.zzz.
-- Its better priority must not promote it back above.
Core.registerVehicles({id = "t.vanG", rooms = {"t.aaa"}, scripts = {"Base.VanG"}})
check("t.aaa named twice now", Core.servingCount("t.aaa"), 2)
check("specificity still wins", Core.roomsForVehicle(vanF)[1], "t.zzz")

-- 9. the generator is nullable and has NO default. A room that says nothing
-- has none; the old {0,0,1} default is what put fifty generators on roofs.
Core.registerRoom("t.tent", {size = {w = 2, h = 2}, locations = {[0] = {0, 1700, 0}}})
Core.registerRoom("t.lit", {size = {w = 2, h = 2}, locations = {[0] = {0, 1800, 0}},
    generator = {x = 0, y = 17, z = 0}})
check("no generator means no power square", Core.slotPower(Core.rooms["t.tent"], 0), nil)
local lit = Core.slotPower(Core.rooms["t.lit"], 0)
check("generator offset applied to y", lit.y, 1817)
check("generator offset applied to x", lit.x, 0)
check("generator z is relative, not assumed", lit.z, 0)

-- 10. A room states nothing about what may carry it.
--
-- There was a `requires` field here -- `trunk` and `battery`, tested per
-- candidate by Core.roomAllows -- and both the field and the function are
-- gone. Nothing on the shipped map ever declared one, and it was a VEHICLE
-- question asked during allocation, which is holder agnostic: put "have you a
-- trunk" to a tent and it cannot answer, and answering no is wrong in a way
-- that is hard to see. Every shipped room once asked for a trunk, so there was
-- no room on the map a tent could be given, and the refusal arrived as "this
-- vehicle has no interior" about a tent.
--
-- What is checked instead is that the field is INERT rather than merely
-- unused: an old third party room set still carries one, and it must load and
-- be ignored rather than refuse anybody.
local function script()
    return {getFullName = function() return "Base.T" end, getName = function() return "T" end}
end
local aVehicle = {getScript = script}
local aTent = {getSprite = function() return nil end}

check("roomAllows is gone", Core.roomAllows, nil)

Core.registerRoom("t.legacyrequires", {
    size = {w = 2, h = 2},
    locations = {[0] = {0, 1900, 0}},
    -- What an old room set ships. It must not stop the room registering.
    requires = {trunk = true}
})
check("a room declaring the old field still registers",
    Core.rooms["t.legacyrequires"] ~= nil, true)
check("and the field is not carried onto the room",
    Core.rooms["t.legacyrequires"].requires, nil)

-- The point of the removal: this room is reachable by whatever its binding
-- names, and by nothing else -- with no second opinion from the room itself.
Core.registerVehicles({id = "t.legacybind", scripts = {"Base.T"},
    rooms = {"t.legacyrequires"}})
check("a vehicle reaches it", Core.roomsForVehicle(aVehicle)[1], "t.legacyrequires")
check("and a tent does not, because no object binding names it",
    #Core.roomsForObject(aTent), 0)

check("a tent is still identified as an object", Core.holderKindOf(aTent), "object")
check("and a vehicle as a vehicle", Core.holderKindOf(aVehicle), "vehicle")

-- 10c. Reachability is the binding's job, not the room's. A vehicle walks only
-- vehicle bindings and an object only object bindings, so neither can be
-- offered the other's rooms in the first place.
Core.registerRoom("t.vanonly", {size = {w = 2, h = 2}, locations = {[0] = {0, 1950, 0}}})
Core.registerRoom("t.tentonly", {size = {w = 2, h = 2}, locations = {[0] = {0, 2000, 0}}})
Core.registerVehicles({id = "t.vanbind", rooms = {"t.vanonly"}, scripts = {"Base.T"}})
Core.registerObjects({id = "t.tentbind", rooms = {"t.tentonly"}, items = {"Base.TentGreen"}})

local aRealTent = {
    getSprite = function()
        return {
            getName = function() return "camping_04_100" end,
            getProperties = function()
                return {has = function(_, k) return k == "CustomItem" end,
                        get = function() return "Base.TentGreen" end}
            end,
            getSpriteGrid = function() return nil end
        }
    end,
    getSquare = function() return nil end
}

local function has(list, want)
    for _, v in ipairs(list) do
        if v == want then return true end
    end
    return false
end

check("the van reaches the van room", has(Core.roomsForVehicle(aVehicle), "t.vanonly"), true)
check("and never the tent room", has(Core.roomsForVehicle(aVehicle), "t.tentonly"), false)
check("the tent reaches the tent room", has(Core.roomsForObject(aRealTent), "t.tentonly"), true)
check("and never the van room", has(Core.roomsForObject(aRealTent), "t.vanonly"), false)
check("roomsForHolder routes a vehicle", has(Core.roomsForHolder(aVehicle), "t.vanonly"), true)
check("and routes an object", has(Core.roomsForHolder(aRealTent), "t.tentonly"), true)

-- 11. a vehicle handle outlives the vehicle. Asking a torn down one whether it
-- is moving used to reach isStopped() -> getController().isGasPedalPressed()
-- and throw from Java with no useful Lua frame.
local function fakeVehicle(opts)
    return {
        isRemovedFromWorld = function() return opts.removed or false end,
        getController = function() return opts.controller end,
        isStopped = function()
            if not opts.controller then
                error("NPE: getController() is null")
            end
            return opts.stopped
        end
    }
end
local live = fakeVehicle({controller = {}, stopped = true})
local rolling = fakeVehicle({controller = {}, stopped = false})
local unloaded = fakeVehicle({controller = nil})
local destroyed = fakeVehicle({removed = true, controller = {}, stopped = false})

check("nil is not live", Core.vehicleIsLive(nil), false)
check("no controller is not live", Core.vehicleIsLive(unloaded), false)
check("removed is not live", Core.vehicleIsLive(destroyed), false)
check("a loaded vehicle is live", Core.vehicleIsLive(live), true)
check("parked is not moving", Core.vehicleIsMoving(live), false)
check("rolling is moving", Core.vehicleIsMoving(rolling), true)
-- The point of the fix: these two must answer rather than throw.
check("unloaded is not moving", Core.vehicleIsMoving(unloaded), false)
check("destroyed is not moving", Core.vehicleIsMoving(destroyed), false)
check("nil is not moving", Core.vehicleIsMoving(nil), false)

-- 12. registration opens exactly once, however many times it is asked to.
-- In SP both server_events and client_events run the boot sequence.
local fired = 0
Events[Core.events.OnRegisterRooms].Add(function() fired = fired + 1 end)
check("first call opens registration", Core.openRegistration(), true)
check("handler ran", fired, 1)
check("second call is a no-op", Core.openRegistration(), false)
check("handler did not run twice", fired, 1)

-- 13. The reverse edge the admin room list reads: which scripts reach a room.
--
-- Unioned across bindings like everything else here, deduplicated across two
-- spellings of one script, and reported in a spelling an author actually
-- wrote -- the index keys on lowercase, and a list rendered from the keys
-- would show a human "base.stepvan". WHICH spelling survives when two
-- bindings disagree is hash order and is deliberately not asserted; the
-- ordering is case insensitive so the list reads alphabetically either way.
Core.registerRoom("r.reach", {size = {w = 2, h = 2}, locations = {[0] = {900, 900, 0}}})
Core.registerRoom("r.wild", {size = {w = 2, h = 2}, locations = {[0] = {960, 900, 0}}})
Core.registerVehicles({id = "r.one", rooms = {"r.reach"}, scripts = {"Base.StepVan"}})
Core.registerVehicles({id = "r.two", rooms = {"r.reach"}, scripts = {"base.stepvan", "Base.Van"}})
Core.registerVehicles({id = "r.wildcard", rooms = {"r.wild"}, match = function() return true end})

local names, matchers = Core.scriptsForRoom("r.reach")
check("scripts are unioned across bindings", #names, 2)
check("and deduplicated case insensitively", string.lower(names[1]), "base.stepvan")
check("ordered case insensitively", string.lower(names[2]), "base.van")
check("no matcher reaches this room", matchers, 0)
check("the count agrees with the list", Core.servingCount("r.reach"), 2)

local wildNames, wildMatchers = Core.scriptsForRoom("r.wild")
check("a matcher names no scripts", #wildNames, 0)
-- Reported separately rather than folded in, or a list would tell an admin
-- that nothing can reach the room anything can reach.
check("but is counted", wildMatchers, 1)
check("a room nobody bound reaches nothing", #(Core.scriptsForRoom("r.orphan")), 0)

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Landings and edges: where each side of a room comes out on the vehicle.
--
-- One map, because there is one question. An ordinary exit no longer exists as
-- a declared thing -- walking out of the box is the way out and the leash
-- handles it -- so what is left is which edge you crossed and what that edge
-- was said to lead to.
-- ---------------------------------------------------------------------------
Core.registerRoom("r.cab", {
    size = {w = 4, h = 5},
    locations = {[0] = {1000, 1000, 0}},
    front = "south",
    cab = true
})
Core.registerRoom("r.nocab", {
    size = {w = 4, h = 5},
    locations = {[0] = {1100, 1000, 0}}
})

local cabRoom = Core.rooms["r.cab"]
check("the front edge survived registration", cabRoom.front, "south")
check("and the cab flag with it", cabRoom.cab, true)

-- The whole point of the reshape: one stated edge, every other answer derived.
-- The old landing table needed a row per edge and could disagree with itself.
check("leaving by the front edge is the front", Core.relativeFor(cabRoom, "south"), "front")
check("the opposite edge is the rear", Core.relativeFor(cabRoom, "north"), "rear")
check("facing south, east is the left flank", Core.relativeFor(cabRoom, "east"), "left")
check("and west is the right", Core.relativeFor(cabRoom, "west"), "right")

-- A room that never said which way its holder points has nothing to be
-- relative TO, so every edge answers nil and its tenants land beside the
-- vehicle exactly as they did before any of this existed.
local noCab = Core.rooms["r.nocab"]
check("a room that said nothing has no front", noCab.front, nil)
check("nor a cab", noCab.cab, false)
check("and no edge of it resolves", Core.relativeFor(noCab, "north"), nil)

-- An edge name that is not one is refused rather than stored, because a front
-- of "backwards" would silently make every exit land beside the vehicle and
-- look exactly like a room that had deliberately said nothing.
Core.registerRoom("r.badfront", {
    size = {w = 4, h = 5},
    locations = {[0] = {1200, 1000, 0}},
    front = "backwards"
})
check("a front that is not an edge is dropped", Core.rooms["r.badfront"].front, nil)

local box = Core.slotBounds(cabRoom, 0)
check("inside the box is over no edge", Core.edgeCrossed(box, 1002, 1002), nil)
check("north of it", Core.edgeCrossed(box, 1002, 999), "north")
check("south of it", Core.edgeCrossed(box, 1002, 1005), "south")
check("west of it", Core.edgeCrossed(box, 999, 1002), "west")
check("east of it", Core.edgeCrossed(box, 1004, 1002), "east")
-- Two squares out is still the same edge, which is the whole reason the cab is
-- an edge rather than the doorway square: a player at a run is never seen on
-- the square, and being outside is a state they stay in.
check("well beyond it is still that edge", Core.edgeCrossed(box, 1002, 1012), "south")
-- Diagonally off a corner is over two edges at once. Which one wins matters
-- far less than it being the same one every run: `pairs` would have picked
-- differently from one boot to the next.
check("a corner picks one and always the same one", Core.edgeCrossed(box, 999, 999), "north")
check("the far corner too", Core.edgeCrossed(box, 1004, 1005), "south")
check("no box, no edge", Core.edgeCrossed(nil, 0, 0), nil)

-- The floor is the footprint less its south row and east column, because those
-- squares are beyond the south and east walls. The leash contains on the floor,
-- so the square just through a south doorway is already outside -- it used to
-- take one more step, and a tenant was two squares out before anything fired.
local floor = Core.slotFloor(cabRoom, 0)
check("the floor keeps the footprint's north-west corner", floor.x1 .. "," .. floor.y1, "1000,1000")
check("and gives up its south row and east column", floor.x2 .. "," .. floor.y2, "1002,1003")
check("the last floor square is still inside", Core.inBounds(floor, 1002, 1003, 0), true)
check("the square through a south doorway is outside the floor", Core.inBounds(floor, 1001, 1004, 0), false)
check("while still inside the footprint the scrub works on", Core.inBounds(box, 1001, 1004, 0), true)
check("and it is over the south edge, so a cab exit fires on it", Core.edgeCrossed(floor, 1001, 1004), "south")
check("likewise the square past the east wall", Core.edgeCrossed(floor, 1003, 1001), "east")
check("slotFloor hands back a fresh box, not the footprint mutated",
    Core.slotBounds(cabRoom, 0).y2, 1004)
check("a missing slot has no floor", Core.slotFloor(cabRoom, 9), nil)

-- Gaps in the index space, which is how a room gives up stamps that changed
-- shape without renumbering the ones that did not. Cell 87,47 became ambulance
-- bays exactly this way.
Core.registerRoom("r.gap", {
    size = {w = 3, h = 3},
    locations = {[0] = {1400, 1000, 0}, [1] = {1410, 1000, 0}, [9] = {1490, 1000, 0}}
})
local gapRoom = Core.rooms["r.gap"]
check("a gapped room keeps only what it was given", #gapRoom.indices, 3)
check("and the surviving indexes keep their numbers", Core.slotOrigin(gapRoom, 9).x, 1490)
check("count is the highest index, not the tally", gapRoom.count, 9)
check("a missing index yields nothing rather than a plausible box",
    Core.slotOrigin(gapRoom, 5), nil)

os.exit(report.finish("registry") == 0 and 0 or 1)
