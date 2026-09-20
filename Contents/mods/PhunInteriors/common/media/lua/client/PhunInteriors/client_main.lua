if isServer() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The client only moves the player and draws menus. Every decision about
-- whether a move is allowed is made server side.
-- ---------------------------------------------------------------------------

Core.client = Core.client or {}
local Client = Core.client

--- True while this client believes it is inside one of our rooms. Used only
--- for menu state; the server is the authority.
Client.inside = false

-- ---------------------------------------------------------------------------
-- Teleporting across the map.
--
-- teleportTo moves the player immediately, but the destination chunk is not
-- loaded yet and the engine restores anyone standing on a square that does not
-- exist. A single call therefore looks like it worked and then silently undoes
-- itself a frame later.
--
-- So we re-assert the position every tick until the destination square is
-- actually there. Re-teleporting also keeps the chunk map centred on the
-- destination, which is what makes it stream in. This matters in both
-- directions: coming back out, the vehicle's chunk has been unloaded all the
-- time the player was inside.
-- ---------------------------------------------------------------------------

local HOLD_TICKS = 180
local SEAT_TICKS = 120

local pending = nil
local holdTeleport

local function stopHolding()
    pending = nil
    Events.OnTick.Remove(holdTeleport)
end

--- The seat we came from if it can still be taken, otherwise the best one
--- going.
--
-- Returns the seat to ENTER by, and optionally a second seat to switch into
-- once aboard. Those differ when the seat somebody left from has no door of
-- its own: boarding by a door seat and switching across is vanilla's own
-- answer (ISVehicleMenu.processEnter), and it is the only way to keep "enter
-- from a seat and be put back in it" true for the rear seat of a VanSeats or
-- an RV.
--
-- Every candidate goes through Core.seatIsEnterable, which is where the door
-- test lives and why. The first branch used to ask isSeatOccupied alone, so it
-- would hand back a seat that was never fitted and, worse, one with no outside
-- position at all -- which is not a quiet failure but a hard error inside
-- ISEnterVehicle:start.
local function resolveSeat(vehicle, wanted, player)
    if Core.seatIsEnterable(vehicle, wanted, player) then
        return wanted
    end

    -- Fitted and empty, but no way into it from the ground. Board wherever we
    -- can switch across from and then switch, which is what a player doing
    -- this by hand would have to do.
    if wanted and wanted >= 0 and vehicle:isSeatInstalled(wanted) and not vehicle:isSeatOccupied(wanted) and
        ISVehicleMenu and ISVehicleMenu.getBestSwitchSeatEnter then
        local door = ISVehicleMenu.getBestSwitchSeatEnter(player, vehicle, wanted)
        if door then
            return door, wanted
        end
    end

    local best = vehicle:getBestSeat(player)
    if Core.seatIsEnterable(vehicle, best, player) then
        return best
    end
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if Core.seatIsEnterable(vehicle, seat, player) then
            return seat
        end
    end
    return nil
end

--- Any seat that can be got into from outside, nearest the front first.
--
-- What a cab exit wants: the door said "put me up front", not "put me back
-- where I was", so there is no preferred seat to honour and nothing to switch
-- across into afterwards. Counting up from 0 gets the driver's seat first,
-- then the passenger, which is the order somebody walking to the front of
-- their own van would expect.
--
-- It is Core.seatIsEnterable rather than isSeatOccupied alone, and the third
-- of its three tests is the one that matters: an RV whose only door is at the
-- front right leaves seat 0 fitted and empty and completely unreachable from
-- the ground, and handing that seat to ISEnterVehicle throws. So a cab exit
-- from a Rolling Refuge lands in the front passenger seat, which is the truth
-- about where that vehicle's door is.
local function firstFreeSeat(vehicle, player)
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if Core.seatIsEnterable(vehicle, seat, player) then
            return seat
        end
    end
    return nil
end

-- Second phase, once the position has landed.
--
-- Vanilla only ever puts a character into a seat from a client timed action,
-- so the re-seat has to happen here. Finding the vehicle does not: the server
-- has already decided which vehicle this is and where it stands, because it
-- holds the lease and it read the position itself. All that is left here is
-- geometry -- take the vehicle at the spot the server named -- and then
-- reporting the id back up so the server can verify it before acting on it.
--
-- Deliberately not a modData UUID match, which is what this used to do. Vehicle
-- level modData is never transmitted to clients: BaseVehicle has getModData and
-- transmitPartModData but none of IsoObject's sync machinery, and vanilla only
-- ever reads part:getModData() client side. So the UUID was always nil here on
-- a dedicated server, the match never succeeded once, and every exit ended in a
-- false "your vehicle is gone" with no re-seat.
--
-- Deliberately not getVehicleById either. It resolves fine server side, but has
-- zero client side uses in vanilla, and the id is reassigned when a vehicle
-- unloads and reloads -- which it always has by this point.
local SEARCH_RADIUS = 3

local function findVehicle()
    return Core.nearestVehicle(pending.x, pending.y, pending.z, SEARCH_RADIUS)
end

-- Where a character stands to use a seat, in world coordinates. Vanilla
-- computes it exactly this way in ISEnterVehicle and ISVehicleMenu, and
-- reuses one Vector3f rather than allocating per call.
local WORLD_POS = Vector3f.new()

local function outsidePosition(vehicle, seat)
    local position = vehicle:getPassengerPosition(seat, "outside")
    if not position then
        return nil
    end
    local worldPos = vehicle:getWorldPos(position:getOffset(), WORLD_POS)
    if not worldPos then
        return nil
    end
    return worldPos:x(), worldPos:y()
end

--- The seat whose door this character is standing nearest, or nil.
--
-- Deliberately not getBestSeat. That returns -1 here, confirmed from the
-- logs: every single capture recorded "door -1", seated entries included, so
-- the door was never actually remembered. Vanilla picks a seat the same way
-- this does, by measuring to each seat's outside position (ISVehicleMenu's
-- distanceToPassengerPosition), which is the same call our own landing code
-- already relies on.
function Client.nearestDoor(vehicle, character)
    local best, bestDistance = nil, nil
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        local x, y = outsidePosition(vehicle, seat)
        if x then
            local dx, dy = x - character:getX(), y - character:getY()
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = seat, distance
            end
        end
    end
    return best
end

-- Vehicle script areas that stand in for each relative direction, best first.
--
-- The room no longer names one of these -- it says which way its holder points
-- and Core.relativeFor turns the crossed edge into "front"/"rear"/"left"/
-- "right". This is the vehicle-side half of that: the only place in the mod
-- that knows a vehicle part name, which is where such knowledge belongs.
--
-- A LIST rather than a name, because declaring an area is optional and widely
-- skipped: the StepVan declares neither TruckBed nor Engine, and lockMartM577
-- declares no TruckBed. A single name meant one undeclared area lost the
-- landing entirely; several give it somewhere else to look first.
--
-- There is deliberately nothing for left and right. No vanilla script declares
-- an area meaning "the flank", so listing a guess here would resolve to
-- something that is not the side -- which is exactly the lie the old per-edge
-- area name told. They fall through to the geometric route below, and failing
-- that to the door.
local AREAS_FOR = {
    front = {"Engine", "Hood"},
    rear = {"TruckBed", "TrunkDoor"},
    left = {},
    right = {}
}

-- Turning left from each relative direction, as a multiple of 90 degrees off
-- the vehicle's forward vector.
local TURN = {
    front = 0,
    left = 1,
    rear = 2,
    right = 3
}

--- A unit vector pointing away from the vehicle in a relative direction, or nil.
--
-- getForwardVector is public on BaseVehicle but has ZERO uses in vanilla lua,
-- which by this project's own rule is a reason to probe rather than to trust.
-- So it is pcall'd and nil-checked, and every caller already has a fallback:
-- if it does not answer, the landing degrades to the nearest door exactly as it
-- did before any of this existed. Nothing depends on it working.
local FORWARD = Vector3f.new()

local function bearing(vehicle, toward)
    local turn = TURN[toward]
    if not turn or not vehicle.getForwardVector then
        return nil
    end
    local ok, forward = pcall(function()
        return vehicle:getForwardVector(FORWARD)
    end)
    if not ok or not forward then
        return nil
    end
    -- x() and z(), not x() and y(). getForwardVector hands back column 2 of
    -- the physics basis, which is a BULLET space vector, and bullet's y is UP.
    -- BaseVehicle.getWorldPos settles it from the bytecode: it builds a world
    -- position as origin.x -> world x, origin.z -> world y, origin.y -> height.
    -- So the map plane is (x, z), and reading y() sampled the vertical axis.
    --
    -- On level ground that component is ~0, so the length test below failed and
    -- this returned nil for every vehicle pointing north or south -- which is
    -- most parked ones. The geometric route then fell through to the nearest
    -- door, and a caravan declares the SAME outside position for all six of its
    -- passengers, so all four ways out landed on one fixed spot on one side.
    -- That is the "sometimes relative to the exit, sometimes not".
    --
    -- A vehicle facing east or west survived it, because there the component
    -- being read happens to be the forward one, so front and rear came out
    -- right and left and right came out a quarter turn off. A fault that is
    -- correct on two headings of four is why it read as inconsistent rather
    -- than as broken.
    local fx, fy = forward:x(), forward:z()
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 0.1 then
        return nil
    end
    fx, fy = fx / length, fy / length
    -- Rotate LEFT `turn` quarter turns. In a y-up frame left is (-fy, fx); PZ's
    -- map y increases SOUTHWARD, so the same formula turns the other way and
    -- left here is (fy, -fx). Check it on a compass rather than by eye: facing
    -- north is (0, -1), and the left hand of somebody facing north points west,
    -- which is (-1, 0).
    --
    -- Written out rather than done with sin and cos, because at multiples of 90
    -- degrees those only introduce floating point fuzz around zero.
    for _ = 1, turn do
        fx, fy = fy, -fx
    end
    return fx, fy
end

--- Standable ground just outside a part of the vehicle, or nil.
--
-- `toward` is relative -- "front", "rear", "left", "right" -- because a room is
-- 4x5 and an ambulance is 2x5 and there is nothing proportional between them,
-- but "you came out of the back" survives the translation.
--
-- An area centre is a point ON the vehicle, not a place to stand. TruckBed is
-- the cargo volume, which for a van is inside the bodywork, and vanilla never
-- stands anybody on one: every getAreaCenter in the base game feeds
-- luautils.walkAdj, which walks ADJACENT to the square rather than onto it. A
-- van has only two seats, both front, so falling back to the nearest door would
-- put a tenant who left by the back of their room at the driver's window, which
-- is the landing doing nothing at all.
--
-- So the centre is used as a DIRECTION rather than a destination: step out from
-- the middle of the vehicle until the square is clear of it. That lands you on
-- the ground immediately behind the van, in line with the part of it the room
-- said you were leaving by.
--
-- Nil when nothing resolves and when nothing clear turns up within STEP_LIMIT,
-- whereupon the caller uses the door position the exit has always used.
--
-- Eight rather than six because the walk starts at the vehicle's middle, so it
-- has to cross half the bodywork before it can clear it, and a semi trailer is
-- ten squares long.
local STEP_LIMIT = 8

function Client.groundBeside(vehicle, toward)
    -- The vehicle's own middle, ALWAYS, with the area used for nothing but the
    -- direction. It used to start the walk at the area centre, which made the
    -- landing distance a property of where the script author happened to put
    -- that rectangle: the FlyingCloud's TruckBed sits 3.4 out on a hull half
    -- 2.9 deep, so the walk began already clear of the vehicle and returned at
    -- once, a square further back than every other way out. Stepping from the
    -- middle gives one rule -- the first square past the bodywork -- and it is
    -- the same rule whichever direction is asked for.
    local cx, cy = vehicle:getX(), vehicle:getY()
    local dx, dy

    for _, area in ipairs(AREAS_FOR[toward] or {}) do
        local centre = vehicle:getAreaCenter(area)
        if centre then
            local ox, oy = centre:getX() - cx, centre:getY() - cy
            local length = math.sqrt(ox * ox + oy * oy)
            -- An area centred on the vehicle gives no direction at all, so it
            -- is no better than not having declared one.
            if length >= 0.1 then
                dx, dy = ox / length, oy / length
                break
            end
        end
    end

    if not dx then
        -- No area spoke for this direction. Ask the vehicle which way it is
        -- pointing instead.
        dx, dy = bearing(vehicle, toward)
    end

    if not dx then
        Core.debugLn("rejoin: nothing resolves '" .. tostring(toward) ..
                         "' on this vehicle; landing at the door instead")
        return nil
    end

    local z = vehicle:getZ()
    for step = 1, STEP_LIMIT do
        -- Tile centres, not the raw float. Everything else in this file lands
        -- on a +0.5, and a fractional position is how a player ends up half
        -- inside the bodywork the square test just called clear.
        local tx = math.floor(cx + dx * step) + 0.5
        local ty = math.floor(cy + dy * step) + 0.5
        local square = getSquare(tx, ty, z)
        if square and not square:getVehicleContainer() and not square:isSolid() then
            return tx, ty
        end
    end

    Core.debugLn("rejoin: no clear ground within " .. STEP_LIMIT .. " of the '" ..
                     tostring(toward) .. "' of this vehicle; landing at the door instead")
    return nil
end

local function rejoinVehicle(player)
    local vehicle = findVehicle()

    if not vehicle then
        pending.seatTicks = pending.seatTicks + 1
        if pending.seatTicks >= SEAT_TICKS then
            -- The chunk is loaded and there is no vehicle in it. Report the
            -- empty result rather than deciding what it means: whether the
            -- vehicle is genuinely gone is a question about the lease, and the
            -- server is the only side holding that.
            Core.debugLn("rejoin: no vehicle within " .. SEARCH_RADIUS .. " squares of " .. pending.x .. "," ..
                             pending.y .. " after " .. pending.seatTicks .. " ticks")
            Core.dispatch(Core.commands.arrived, {})
            stopHolding()
        end
        return
    end

    -- A cab exit wants a seat, any seat, and has no preference to honour: the
    -- door said "put me in the front", not "put me back where I was". Every
    -- other exit only re-seats somebody who was seated on the way in, because
    -- a player who walked up to the van on foot should come back out on foot.
    local seat, switchTo = nil, nil
    if pending.cab then
        seat = firstFreeSeat(vehicle, player)
        if not seat then
            -- Reported rather than worked around. The server still holds the
            -- lease, so it can put them back in the room, and standing them
            -- next to a full van would be the cab exit silently doing nothing.
            Core.debugLn("rejoin: cab exit, but every seat is taken")
        end
    elseif pending.seat and pending.seat >= 0 then
        seat, switchTo = resolveSeat(vehicle, pending.seat, player)
        if not seat then
            Core.debugLn("rejoin: every seat is occupied, staying outside")
        end
    end

    -- Land beside the vehicle rather than in the middle of its model. The
    -- server can only ever send us the vehicle position, which is its centre.
    --
    -- This is also what makes re-seating work at all: ISEnterVehicle:start()
    -- silently returns without entering when the character is more than two
    -- tiles from this exact position, and the centre of a van is further than
    -- that. isValid then drops the action, so it failed by leaving the player
    -- standing there. Confirmed from the logs, which recorded "seat 0
    -- requested, taking 0" on an exit that put the player outside.
    -- The seat we are retaking, else the door we came in by, else whatever is
    -- nearest. Without the middle one every on-foot exit uses the same door,
    -- because getBestSeat is measured from the vehicle centre we land on.
    -- The part of the vehicle the room says this way out comes out at, if the
    -- room said anything and this vehicle declares it.
    --
    -- Tried first, because when it resolves it is a better answer than any
    -- seat door: it is where the room told the player they would end up.
    -- getAreaCenter returns world coordinates with the vehicle's rotation
    -- already applied, and nil for an area the script does not declare -- which
    -- is not an edge case, the StepVan declares neither TruckBed nor Engine.
    local x, y
    if pending.toward and not seat then
        x, y = Client.groundBeside(vehicle, pending.toward)
    end

    if not x then
        local standAt = seat or pending.standSeat
        if not standAt or standAt < 0 then
            standAt = Client.nearestDoor(vehicle, player)
        end
        if not standAt or standAt < 0 then
            standAt = 0
        end
        x, y = outsidePosition(vehicle, standAt)
    end

    if x then
        player:teleportTo(x, y, player:getZ())
    end

    if seat then
        Core.debugLn("rejoin: seat " .. tostring(pending.seat) .. " requested, taking " .. tostring(seat))
        ISTimedActionQueue.add(ISEnterVehicle:new(player, vehicle, seat))

        -- The seat they left from has no door of its own, so they boarded by
        -- one that has. Vanilla queues the switch the same way, with the seat
        -- we came in by passed explicitly: ISSwitchVehicleSeat works it out
        -- from getVehicle() otherwise, and at queue time they are still
        -- standing on the road.
        if switchTo then
            Core.debugLn("rejoin: switching across to seat " .. tostring(switchTo))
            ISTimedActionQueue.add(ISSwitchVehicleSeat:new(player, switchTo, seat))
        end
    end

    -- Close the handshake. The server checks this id against the lease before
    -- it does anything with it, so a wrong guess here is caught rather than
    -- charged to somebody else's vehicle. This is the direction of travel
    -- vanilla proves: clients send getId() up and servers resolve it with
    -- getVehicleById, roughly thirty times in VehicleCommands.lua.
    Core.dispatch(Core.commands.arrived, {
        id = vehicle:getId(),
        -- Only meaningful for a cab exit, and the one thing the server cannot
        -- work out for itself: it did not have a loaded vehicle to ask.
        seated = seat ~= nil
    })

    stopHolding()
end

function holdTeleport()
    local player = getPlayer()
    if not pending or not player then
        stopHolding()
        return
    end

    if pending.arrived then
        rejoinVehicle(player)
        return
    end

    pending.ticks = pending.ticks + 1

    local square = getCell() and getCell():getGridSquare(pending.x, pending.y, pending.z)
    local arrived = square ~= nil and math.floor(player:getX()) == pending.x and math.floor(player:getY()) == pending.y

    if arrived then
        Core.debugLn(string.format("teleport: arrived at %s,%s,%s after %d tick(s)", tostring(pending.x),
            tostring(pending.y), tostring(pending.z), pending.ticks))
        -- Coming back out there is a second phase: wait for the vehicle to
        -- appear in the freshly streamed chunk, then get back in it.
        if pending.rejoin then
            pending.arrived = true
            pending.seatTicks = 0
            return
        end
        -- No vehicle to climb back into, but the server still has something it
        -- can only do while this chunk is loaded -- unlocking the tent that
        -- was just left. Reported the moment the square exists rather than
        -- after a second phase, because there is nothing to wait for.
        if pending.report then
            Core.dispatch(Core.commands.arrived, {})
        end
        stopHolding()
        return
    end

    if pending.ticks >= HOLD_TICKS then
        Core.logLn(string.format(
            "teleport: gave up after %d ticks; %s,%s,%s never loaded (square is %s, player at %s,%s)", pending.ticks,
            tostring(pending.x), tostring(pending.y), tostring(pending.z), square and "there" or "still nil",
            tostring(player:getX()), tostring(player:getY())))
        stopHolding()
        return
    end

    player:teleportTo(pending.x + 0.5, pending.y + 0.5, pending.z)
end

function Client.teleport(data)
    local player = getPlayer()
    if not player or not data then
        return
    end

    -- Put away anything that watches where the player is standing.
    --
    -- A teleport leaves the player with no square at all until the
    -- destination chunk streams in, and vanilla UI does not expect that.
    -- ISBuildWindow:update calls originalSquare:DistToProper(player:getSquare())
    -- to decide whether to auto-close, which throws a NullPointerException on
    -- the nil square and then a cascade of __le failures every frame after.
    -- Vanilla has the same instinct in ISEnterVehicle:start, which clears the
    -- drag cursor and hides the context menu before moving anybody.
    local playerNum = player:getPlayerNum()
    if getCell() then
        getCell():setDrag(nil, playerNum)
    end
    local contextMenu = getPlayerContextMenu(playerNum)
    if contextMenu and contextMenu:isAnyVisible() then
        contextMenu:hideAndChildren()
    end
    if ISBuildWindow and ISBuildWindow.instance then
        -- pcall because this reaches into vanilla UI state we do not own
        pcall(function()
            ISBuildWindow.instance:close()
        end)
    end

    -- Out of the seat first. player:getVehicle() is the test; BaseVehicle has
    -- no isInVehicle. Nil on the way back out of a room, so this no-ops there.
    local vehicle = player:getVehicle()
    if vehicle then
        vehicle:exit(player)
        triggerEvent("OnExitVehicle", player)
    end

    Core.debugLn(string.format("teleport: asked for %s,%s,%s; player at %s,%s,%s", tostring(data.x), tostring(data.y),
        tostring(data.z), tostring(player:getX()), tostring(player:getY()), tostring(player:getZ())))

    player:teleportTo(data.x + 0.5, data.y + 0.5, data.z)

    -- Hold it there until the chunk exists. A fresh request replaces any
    -- in-flight one rather than stacking a second handler.
    local wasPending = pending ~= nil
    pending = {
        x = math.floor(data.x),
        y = math.floor(data.y),
        z = math.floor(data.z),
        ticks = 0,
        arrived = false,
        -- Only set on the way out; nil going in, which skips the second phase.
        rejoin = data.rejoin and true or false,
        -- "the server is waiting to hear that you landed", which a world
        -- object exit owes and an admin port does not.
        report = data.report and true or false,
        seat = data.seat,
        -- "take any free seat", set by a cab exit
        cab = data.cab and true or false,
        -- which part of the vehicle to come out at: front/rear/left/right
        toward = data.toward,
        standSeat = data.standSeat
    }
    if not wasPending then
        Events.OnTick.Add(holdTeleport)
    end

    Client.inside = data.inside and true or false
end

function Client.notify(data)
    if not data or not data.text then
        return
    end
    local player = getPlayer()
    if not player then
        return
    end
    local text = getText(data.text)
    if data.warning then
        player:setHaloNote(text, 255, 180, 60, 300)
    else
        player:setHaloNote(text, 200, 220, 200, 300)
    end
end

--- Ask to go inside a placed world object -- a tent, and whatever follows it.
--
-- Sends the square and nothing else. The server reads the object off it, so
-- there is no identity here for a client to get wrong or to forge, and none of
-- the vehicle path's paraphernalia applies: nothing to climb out of, no seat
-- to remember, and no motion to be refused for.
function Client.requestEnterObject(square)
    if not square then
        return
    end
    Core.dispatch(Core.commands.enterObject, {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ()
    })
end

--- Ask to go in. The server decides.
function Client.requestEnter(vehicle, seat, standSeat)
    if not vehicle then
        return
    end
    Core.dispatch(Core.commands.enter, {
        x = vehicle:getX(),
        y = vehicle:getY(),
        z = vehicle:getZ(),
        -- Read before the character left the seat; see client_enter.
        seat = seat,
        -- The door they are stood at, so they come back out at the same one.
        standSeat = standSeat
    })
end

--- Ask to come out. Normally you walk out and the leash does this without
--- being asked, but the context menu is a discoverable affordance and a safety
--- net -- and it is the only way out of a room whose door has been blocked.
function Client.requestLeave()
    Core.dispatch(Core.commands.leave, {
        reason = "menu"
    })
end

-- ---------------------------------------------------------------------------
-- Admin entry point.
--
-- admin.lua's handler and the adminResult printer both existed, but nothing
-- ever dispatched between them, so with PhunServer2 absent -- which is the
-- normal case, since it is a soft hook and never a dependency -- the whole
-- admin surface was unreachable.
--
-- This is the single client side caller. Type it into the debug console:
--
--     PhunInteriors.admin("list")
--     PhunInteriors.admin("rooms")    -- what exists, and what can reach it
--     PhunInteriors.admin("enter", {room = "phun.van.roofed"})
--     PhunInteriors.admin("enter", {room = "phun.van.roofed", index = 9})
--     PhunInteriors.admin("release", {room = "phun.van.roofed", index = 9})
--     PhunInteriors.admin("remanifest", {room = "phun.van", index = 4})
--     PhunInteriors.admin("scrub", {room = "phun.van", index = 3})
--     PhunInteriors.admin("free", {vehicleId = "..."})
--     PhunInteriors.admin("age", {vehicleId = "...", days = 99})
--     PhunInteriors.admin("reclaim")  -- or {room = "..."}; what a full pool would take
--     PhunInteriors.admin("reload")   -- after changing a sandbox option
--     PhunInteriors.admin("weight")
--     PhunInteriors.admin("shove")   -- or {radius = 6}; clears the ground round you
--     PhunInteriors.admin("evict", {username = "..."})
--
-- Results come back through Core.commands.adminResult and print to the log,
-- which is also where they land in multiplayer. The server re-checks admin
-- rights in server_commands, so this is an entry point, not a bypass.
--
-- Deliberately one function taking an action name rather than a function per
-- action: it is the same shape PhunServer2's chat command drives, and the same
-- shape an admin UI would drive later, so none of this gets rewritten.
-- ---------------------------------------------------------------------------
--- Build a room from where you are standing and emit the lua for it.
--
--     PhunInteriors.author("begin", {id = "yourmod.van"})
--     PhunInteriors.author("corner")   -- twice, opposite corners of room 1
--     PhunInteriors.author("spawn")    -- standing on the spawn tile
--     PhunInteriors.author("cab")      -- optional, at the wall whose doorway
--                                      -- should put you in a seat
--     PhunInteriors.author("power")    -- standing on the generator square
--     PhunInteriors.author("strip", {count = 38, pitchX = 60})
--     PhunInteriors.author("scripts", {scripts = "Base.Van, Base.VanSeats", match = "Van"})
--     PhunInteriors.author("sweep")    -- repeat as you walk the strip
--     PhunInteriors.author("emit")
--
-- Same dispatcher shape as admin, for the same reason: a panel later is a
-- view over these calls rather than a rewrite.
--- Everything the caller passed, minus anything that would not survive the
--- trip to a dedicated server.
--
-- These used to name each field they forwarded, which meant every new action
-- silently dropped any argument nobody remembered to add to the list. It cost
-- a debugging session: admin("age", {days = 13}) never sent days at all, so
-- the server fell through to its default and reported a number the caller had
-- never asked for.
local function payload(action, args, fallback)
    local out = {
        action = action or fallback
    }
    for key, value in pairs(args or {}) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            out[key] = value
        else
            Core.logLn("dropping '" .. tostring(key) .. "' from the command: a " .. kind ..
                           " cannot be sent to the server")
        end
    end
    return out
end

function Core.author(action, args)
    Core.dispatch(Core.commands.author, payload(action, args, "status"))
    return "sent; results are printed to the log"
end

function Core.admin(action, args)
    Core.dispatch(Core.commands.admin, payload(action, args, "list"))
    return "sent; results are printed to the log"
end

return Client
