if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Weight = require "PhunInteriors/weight"
local Transit = {}
Core.modules.transit = Transit

-- ---------------------------------------------------------------------------
-- Getting in and out.
--
-- There is exactly one way out. Walking onto an exit tile, stepping through a
-- hole in the wall, and tripping the leash all call Transit.leave, which puts
-- the player back at the vehicle. No breach handler, no snap back branch.
--
-- Leaving is a three step handshake, because no one side can answer the whole
-- question. The server decides where the player goes and which seat they are
-- owed; the client moves them, because vanilla only ever seats a character
-- from a client timed action; then the client reports which vehicle it
-- actually found, which is the first moment anybody can tell an unloaded
-- vehicle from a destroyed one.
-- ---------------------------------------------------------------------------

-- Below this a vehicle counts as parked. Matches the client tracker.
local MOVING_KMH = 0.2
-- How long to hold a player's exit paperwork open waiting for them to report
-- that they landed.
local ARRIVAL_TIMEOUT_MS = 30000

-- playerKey -> what is still owed once they confirm where they came out.
local pendingArrivals = {}

local function notify(player, textKey, isWarning)
    Core.respond(player, Core.commands.notify, {
        text = textKey,
        warning = isWarning and true or false
    })
end

-- How often a refused exit is allowed to say so.
local WARN_INTERVAL_MS = 5000

--- Notify, but not four times a second.
--
-- Every refusal in Transit.leave is reachable from the exit tile, and the
-- leash re-tests that tile every 250ms for as long as the player is stood on
-- it. Without this, being unable to get out means a wall of halo notes rather
-- than one piece of information.
local function notifyThrottled(player, occupancy, textKey)
    local now = getTimestampMs()
    if occupancy.warnedAt and (now - occupancy.warnedAt) < WARN_INTERVAL_MS then
        return
    end
    occupancy.warnedAt = now
    notify(player, textKey, true)
end

--- Count zombies near a point. Used for both the entry gate and the exit tax.
local function zombiesNear(x, y, z, radius)
    local count = 0
    local cell = getCell()
    for ix = math.floor(x - radius), math.floor(x + radius) do
        for iy = math.floor(y - radius), math.floor(y + radius) do
            local square = cell:getGridSquare(ix, iy, z)
            if square then
                local moving = square:getMovingObjects()
                if moving then
                    for i = 0, moving:size() - 1 do
                        local object = moving:get(i)
                        if object and instanceof(object, "IsoZombie") and not object:isDead() then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count
end
Transit.zombiesNear = zombiesNear

--- Can this player enter this vehicle right now?
-- Returns true, or false plus a translation key.
function Transit.canEnter(player, vehicle)
    if not player or not vehicle then
        return false, "IGUI_PhunInteriors_NoVehicle"
    end

    local class = Core.classForVehicle(vehicle)
    if not class then
        return false, "IGUI_PhunInteriors_WrongVehicle"
    end

    local allowed, reason = Core.vehicleAllows(vehicle, class)
    if not allowed then
        return false, reason
    end

    if Core.settings.EntryBlockedByZombies then
        local radius = Core.settings.EntryZombieRadius or 4
        if zombiesNear(vehicle:getX(), vehicle:getY(), vehicle:getZ(), radius) > 0 then
            return false, "IGUI_PhunInteriors_ZombiesTooClose"
        end
    end

    return true, class
end

--- Put a player inside. Server authoritative; the client only does the move.
function Transit.enter(player, vehicle, seat, standSeat)
    local ok, classOrReason = Transit.canEnter(player, vehicle)
    if not ok then
        notify(player, classOrReason, true)
        return false
    end
    local class = classOrReason

    local vehicleId = Core.vehicleId(vehicle, true)
    local assignment, reason, dirty = Slots.acquire(vehicleId, class.roomSet)
    if not assignment then
        notify(player, reason, true)
        return false
    end

    -- A slot handed over straight from quarantine still holds the last
    -- tenant's mess. Try to clean it now: if another player is in a
    -- neighbouring slot the chunk is already loaded and this succeeds, and
    -- nobody ever sees it. Otherwise the leash finishes the job on arrival,
    -- which is the first moment the chunk is guaranteed to exist.
    local scrubOnArrival = false
    if dirty then
        local Scrub = require "PhunInteriors/scrub"
        local cleaned, why = Scrub.slot(assignment.roomSet, assignment.index)
        if not cleaned then
            Core.debugLn(string.format("%s#%s still dirty (%s); scrubbing on arrival",
                tostring(assignment.roomSet), tostring(assignment.index), tostring(why)))
            scrubOnArrival = true
        end
    end
    Slots.touch(vehicleId)

    -- Who to warn before this lease expires
    assignment.lastUser = Core.playerKey(player)

    -- Persisted so a player who logs in inside the room after a restart still
    -- has somewhere to come out, even if the vehicle is unloaded by then.
    assignment.lastKnownVehiclePos = {
        x = vehicle:getX(),
        y = vehicle:getY(),
        z = vehicle:getZ()
    }
    -- Good until the vehicle unloads, which is usually seconds from now. The
    -- tracker refreshes it whenever somebody drives this thing again.
    assignment.lastKnownHandle = vehicle:getId()

    local set = Core.roomSets[assignment.roomSet]
    local spawn = Core.slotSpawn(set, assignment.index)
    local key = Core.playerKey(player)

    -- If nobody has ever had this room, it is pristine, and the leash will
    -- capture its blueprint as soon as it sees the player actually inside it.
    -- That is the only moment the room is both loaded and untouched: the
    -- chunk is not loaded here, and it stops being pristine the moment the
    -- tenant moves a chair.
    local pristine = Slots.markUsed(assignment.roomSet, assignment.index)

    -- The client reads this before the character leaves the seat, because by
    -- the time the request lands here getSeat would already return -1. Bound
    -- it rather than trusting it: the worst a bad value could do is drop the
    -- player into a different seat of their own vehicle, but there is no
    -- reason to accept one.
    local requestedSeat = tonumber(seat) or -1
    if requestedSeat < 0 or requestedSeat >= vehicle:getMaxPassengers() then
        requestedSeat = -1
    end

    -- Which door to put them back at. Separate from the seat: someone who
    -- walked up on foot has no seat to retake but still got in somewhere, and
    -- coming back out at the same door beats always using the same one.
    local requestedDoor = tonumber(standSeat) or -1
    if requestedDoor < 0 or requestedDoor >= vehicle:getMaxPassengers() then
        requestedDoor = -1
    end

    -- A room set points at coordinates that only exist if the map providing
    -- them was present when the world was created. PZ writes the meta grid at
    -- creation, so a map added to an existing save is in the mod list and the
    -- map group but not in the world. Teleporting there moves the player for a
    -- frame and the engine then restores them to the last real square, which
    -- reads downstream as an instant breach.
    --
    -- Refuse up front instead: a room we cannot put the player in is not a room.
    local grid = getWorld() and getWorld():getMetaGrid()
    if grid and not grid:isValidSquare(spawn.x, spawn.y) then
        Core.logLn(string.format(
            "%s#%s spawns at %s,%s, which is outside this world. Meta grid runs "
            .. "%s-%s x %s-%s. The map was almost certainly added after this "
            .. "world was created; a new world is needed to pick it up.",
            tostring(assignment.roomSet), tostring(assignment.index),
            tostring(spawn.x), tostring(spawn.y),
            tostring(grid:getMinX()), tostring(grid:getMaxX()),
            tostring(grid:getMinY()), tostring(grid:getMaxY())))
        Slots.release(vehicleId, "destination not in this world")
        notify(player, "IGUI_PhunInteriors_RoomNotInWorld", true)
        return false
    end

    -- Snapshot the crowd we are walking away from. The exit tax grows this
    -- while the player is inside, so waiting out the night costs something.
    local snapshot = 0
    if Core.settings.ExitTax then
        snapshot = zombiesNear(vehicle:getX(), vehicle:getY(), vehicle:getZ(), 15)
    end

    Core.occupants[key] = {
        vehicleId = vehicleId,
        -- session-scoped handle, for the live lookup in resolveReturn
        vehicleHandle = vehicle:getId(),
        -- Give the teleport time to land before the leash starts judging. Must
        -- outlast the client's HOLD_TICKS window, or the leash ejects a player
        -- who is still waiting for the destination chunk to stream in.
        graceUntil = getTimestampMs() + 6000,
        roomSet = assignment.roomSet,
        index = assignment.index,
        seat = requestedSeat,
        standSeat = requestedDoor,
        captureSlot = pristine or nil,
        captureTries = 0,
        scrubOnArrival = scrubOnArrival or nil,
        scrubTries = 0,
        enteredAt = Core.now(),
        zombieSnapshot = snapshot,
        returnTo = {
            x = vehicle:getX(),
            y = vehicle:getY(),
            z = vehicle:getZ()
        }
    }

    -- Getting the player out of the seat happens client side, with the
    -- teleport, because vanilla only ever exits a vehicle from a client timed
    -- action. The seat is already captured above.

    Core.respond(player, Core.commands.teleport, {
        x = spawn.x,
        y = spawn.y,
        z = spawn.z,
        inside = true
    })

    triggerEvent(Core.events.OnEnter, player, vehicle, assignment)
    Core.debugLn(tostring(key) .. " entered " .. assignment.roomSet .. "#" .. assignment.index ..
        " from seat " .. tostring(requestedSeat) .. ", door " .. tostring(requestedDoor))
    return true
end

--- Record where a leased vehicle is, from a client that can see it moving.
--
-- The client sends an id and nothing else, so this reads the position from the
-- vehicle itself and there is nothing here to take on trust. The id has to be
-- resolvable, which means the chunk is loaded, which it is -- somebody is
-- driving it.
--
-- Both halves matter. The position is what an exit falls back on, and the
-- handle is how the next lookup finds the vehicle at all: getId() is
-- reassigned every time a vehicle unloads and reloads, so the one captured
-- when the tenant went inside is dead within minutes.
function Transit.notePosition(handle)
    if not handle then
        return false
    end
    local vehicle = getVehicleById(handle)
    if not vehicle then
        -- Ordinary enough: a player can park and step inside before this
        -- lands, and by then the chunk may be on its way out.
        return false
    end
    local vehicleId = Core.vehicleId(vehicle, false)
    local assignment = vehicleId and Slots.find(vehicleId)
    if not assignment then
        -- A registered vehicle class that nobody has leased an interior to.
        -- The client cannot tell the difference, so it pushes for all of them.
        return false
    end

    assignment.lastKnownVehiclePos = {
        x = vehicle:getX(),
        y = vehicle:getY(),
        z = vehicle:getZ()
    }
    assignment.lastKnownHandle = handle
    return true
end

--- The vehicle, if it is loaded right now.
local function liveVehicle(occupancy, assignment)
    -- Two handles worth trying. The tracked one is current, refreshed by
    -- whoever last drove it. The one captured on the way in is usually dead --
    -- the vehicle unloads as soon as its owner walks off to a room 10,000
    -- tiles away, and reloads carrying a different id.
    local handles = {}
    if assignment and assignment.lastKnownHandle then
        table.insert(handles, assignment.lastKnownHandle)
    end
    if occupancy.vehicleHandle then
        table.insert(handles, occupancy.vehicleHandle)
    end

    for _, handle in ipairs(handles) do
        local candidate = getVehicleById(handle)
        -- getId() is a short and is reused, so confirm against the lease key.
        if candidate and Core.vehicleId(candidate, false) == occupancy.vehicleId then
            return candidate
        end
    end

    -- No handle resolved, which usually means the vehicle is unloaded -- and an
    -- unloaded vehicle is stationary by definition, because unloaded means no
    -- player is near enough to be driving it.
    --
    -- Usually, but not always: a vehicle that reloaded and has not been driven
    -- since is loaded while every handle we hold is dead, and that includes the
    -- second or two between somebody driving off and the tracker's first push.
    -- Treating that as frozen would send the player to a parking space the van
    -- has just left. One sweep, at the only moment the answer matters.
    local position = assignment and assignment.lastKnownVehiclePos
    if position then
        local found = Core.vehicleNear(position.x, position.y, position.z, occupancy.vehicleId)
        if found then
            assignment.lastKnownHandle = found:getId()
            return found
        end
    end

    return nil
end

--- Resolve where a player should come out.
--
-- Live first when the vehicle happens to be loaded, because then the position
-- is simply true. Otherwise the stored one, which is not a stale cache in any
-- way that can hurt: an unloaded vehicle cannot move, so the last position the
-- tracker saw is still where it is. The tracker's whole job is making sure
-- that position was accurate at the instant it unloaded.
--
-- Ordering matters between the two stored ones. lastKnownVehiclePos is kept
-- current by the tracker; occupancy.returnTo is only ever the position at the
-- moment the tenant went inside, and is here for a lease that predates any
-- tracking.
local function resolveReturn(occupancy)
    local assignment = Slots.find(occupancy.vehicleId)
    local vehicle = liveVehicle(occupancy, assignment)

    if vehicle then
        return {
            x = vehicle:getX(),
            y = vehicle:getY(),
            z = vehicle:getZ()
        }, vehicle
    end

    return (assignment and assignment.lastKnownVehiclePos) or occupancy.returnTo, nil
end

--- A seat this player could be put into, preferring the one they came from.
local function freeSeat(vehicle, preferred)
    if preferred and preferred >= 0 and vehicle:isSeatInstalled(preferred)
        and not vehicle:isSeatOccupied(preferred) then
        return preferred
    end
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if vehicle:isSeatInstalled(seat) and not vehicle:isSeatOccupied(seat) then
            return seat
        end
    end
    return nil
end

--- Take a player out. reason is one of "exit", "leash", "breach", "admin".
function Transit.leave(player, reason)
    local key = Core.playerKey(player)
    local occupancy = Core.occupants[key]
    if not occupancy then
        return false
    end

    local destination, vehicle = resolveReturn(occupancy)
    if not destination then
        -- Nothing to fall back on. Refusing silently strands the player with a
        -- dead exit tile and no idea why, so say so; the lease survives, and
        -- an admin can evict them.
        Core.logLn("could not resolve a return position for " .. tostring(key))
        notifyThrottled(player, occupancy, "IGUI_PhunInteriors_VehicleGone")
        return false
    end

    -- You do not step out of a moving vehicle onto the road.
    --
    -- Only askable when the vehicle is loaded, which is exactly when it can be
    -- moving; an unloaded one cannot. The test is speed rather than
    -- getDriver(), because a towed vehicle moves with nobody at its wheel --
    -- that is what vanilla's getDriverRegardlessOfTow exists for.
    --
    -- A free seat makes it allowable, and forces the exit to use that seat
    -- even for somebody who walked up on foot. Refusing is self resolving:
    -- the driver parks, logs off or crashes, and then it is stationary.
    local seatOut = nil
    if vehicle and math.abs(vehicle:getCurrentSpeedKmHour()) >= MOVING_KMH then
        seatOut = freeSeat(vehicle, occupancy.seat)
        if not seatOut then
            Core.debugLn(tostring(key) .. " tried to leave a moving vehicle with no free seat")
            notifyThrottled(player, occupancy, "IGUI_PhunInteriors_VehicleMoving")
            return false
        end
    end

    -- Weight is only recomputed here. It matters when driving, and the player
    -- cannot drive from inside, so detecting every item move would cost a lot
    -- for no gameplay difference.
    --
    -- Measured now, because the room is loaded now: the player is standing in
    -- it. Applying it is a different question -- the vehicle is almost never
    -- loaded at this point -- so that is deferred until it can be found.
    local interiorWeight = Weight.ofSlot(occupancy.roomSet, occupancy.index)
    if vehicle then
        Weight.apply(vehicle, interiorWeight)
    end

    -- What is still owed once the player confirms they landed. Applying the
    -- mass needs the vehicle loaded, and it is not loaded here -- it will be
    -- the moment the player arrives on top of it, so this waits for their
    -- report rather than for a timer to notice.
    pendingArrivals[key] = {
        vehicleId = occupancy.vehicleId,
        -- nil when it was applied above, because the vehicle was already loaded
        weight = (not vehicle) and interiorWeight or nil,
        expires = getTimestampMs() + ARRIVAL_TIMEOUT_MS
    }

    -- The exit tax. Zombies accumulate rather than despawning, so you come out
    -- into a bigger crowd than you left.
    local owed = 0
    if Core.settings.ExitTax and occupancy.zombieSnapshot > 0 then
        local hours = Core.now() - (occupancy.enteredAt or Core.now())
        local growth = tonumber(Core.settings.ExitTaxGrowth) or 0
        owed = math.floor(occupancy.zombieSnapshot + (hours * growth))
        Core.debugLn(string.format("exit tax: snapshot %d over %.1fh -> %d",
            occupancy.zombieSnapshot, hours, owed))
    end

    Core.occupants[key] = nil
    if occupancy.vehicleId then
        Slots.touch(occupancy.vehicleId)
    end

    -- Rejoining the seat is a client timed action, and the vehicle is very
    -- likely still unloaded at this point, so hand the client what it needs to
    -- do it once the destination chunk has streamed in.
    --
    -- No vehicle identity goes down with this. The client takes whatever
    -- vehicle is at the position we just named and tells us which one that
    -- was; we check it against the lease in Transit.arrived. Sending our UUID
    -- for the client to match on could never have worked, because vehicle
    -- level modData is not transmitted to clients at all.
    Core.respond(player, Core.commands.teleport, {
        x = destination.x,
        y = destination.y,
        z = destination.z,
        inside = false,
        reason = reason,
        rejoin = true,
        seat = seatOut or occupancy.seat,
        standSeat = occupancy.standSeat
    })

    -- Deliberately no "your vehicle is gone" warning here. While the player was
    -- inside, the vehicle almost always unloaded, so from this side an unloaded
    -- vehicle and a destroyed one are indistinguishable and this fired on every
    -- ordinary exit. Transit.arrived raises it instead, once the player is
    -- standing in a loaded chunk and the question has an answer.
    if not vehicle then
        Core.debugLn("leave: vehicle not loaded here; waiting for the arrival report")
    end

    triggerEvent(Core.events.OnExit, player, reason, owed)
    Core.debugLn(tostring(key) .. " left via " .. tostring(reason))
    return true, owed
end

--- The player landed back outside and is telling us what they found there.
--
-- This is the moment the exit could not be finished at. When Transit.leave
-- ran, the vehicle's chunk was unloaded and so was every answer that depends
-- on seeing it: whether it still exists, where it is now, what its interior
-- weighs against it. The player arriving is what loads that chunk.
--
-- handle is the client's answer to "which vehicle is at the spot you sent me
-- to", and it is checked, not taken. The server holds the lease, so it is the
-- only side that can say whether that is the right vehicle.
function Transit.arrived(player, handle)
    local key = Core.playerKey(player)
    local record = pendingArrivals[key]
    if not record then
        -- Duplicate report, or one that outlived its window. Nothing owed.
        return false
    end
    pendingArrivals[key] = nil

    local vehicle = handle and getVehicleById(handle)
    if vehicle and Core.vehicleId(vehicle, false) ~= record.vehicleId then
        -- Somebody else's vehicle parked where yours was. Rare, and it must
        -- not be charged for what your room holds.
        Core.logLn("arrival from " .. tostring(key) ..
            " named a vehicle that does not hold the lease; ignoring it")
        vehicle = nil
    end

    if not vehicle then
        -- Now this is a true statement rather than a guess. The player is
        -- standing in a loaded chunk and their vehicle is not in it.
        Core.debugLn(tostring(key) .. " came out and the vehicle was not there")
        notify(player, "IGUI_PhunInteriors_VehicleGone", true)
        return false
    end

    -- It is loaded right now, which is rare enough to be worth banking.
    Transit.notePosition(handle)

    if record.weight then
        Weight.apply(vehicle, record.weight)
    end
    return true
end

--- Drop exit paperwork nobody came back to claim.
--
-- Only reachable if a client vanished between being sent out and landing --
-- a disconnect mid teleport. The weight is recalculated from scratch on the
-- next exit, so losing one costs nothing permanent.
function Transit.sweepArrivals()
    local now = getTimestampMs()
    for key, record in pairs(pendingArrivals) do
        if now > record.expires then
            Core.debugLn("no arrival report from " .. tostring(key) ..
                "; interior weight will be applied on their next exit")
            pendingArrivals[key] = nil
        end
    end
end

--- Is this player currently inside one of our rooms?
function Transit.occupancyOf(player)
    return Core.occupants[Core.playerKey(player)]
end

--- Rebuild occupancy for a player who logged in already inside a room, eg
--- after a server restart. Beats the reference approach of minting a fresh
--- random id and guessing by proximity.
function Transit.recover(player)
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local store = Slots.store()

    for vehicleId, assignment in pairs(store.assignments) do
        local set = Core.roomSets[assignment.roomSet]
        if set then
            local bounds = Core.slotBounds(set, assignment.index)
            if Core.inBounds(bounds, x, y, z) then
                Core.occupants[Core.playerKey(player)] = {
                    vehicleId = vehicleId,
                    roomSet = assignment.roomSet,
                    index = assignment.index,
                    seat = -1,
                    enteredAt = Core.now(),
                    zombieSnapshot = 0,
                    returnTo = assignment.lastKnownVehiclePos
                }
                Core.logLn("recovered " .. tostring(Core.playerKey(player)) ..
                    " inside " .. assignment.roomSet .. "#" .. assignment.index)
                return true
            end
        end
    end

    return false
end

return Transit
