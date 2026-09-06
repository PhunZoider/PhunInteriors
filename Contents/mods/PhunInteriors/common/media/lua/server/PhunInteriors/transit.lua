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
-- ---------------------------------------------------------------------------

local function notify(player, textKey, isWarning)
    Core.respond(player, Core.commands.notify, {
        text = textKey,
        warning = isWarning and true or false
    })
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

--- Resolve where a player should come out.
--
-- Live lookup first: the reference mod caches vehicle position on a one minute
-- timer, so somebody driving your van while you are inside drops you up to
-- sixty seconds in the past, or inside geometry.
local function resolveReturn(occupancy)
    -- getCell():getVehicles() returns a java.util.Set. It has size() but no
    -- get(i), so it cannot be indexed from Lua at all. getVehicleById is the
    -- direct lookup and is what vanilla VehicleCommands.lua uses. It returns
    -- nil for an unloaded vehicle, which is the semantics we want: an unloaded
    -- vehicle correctly falls through to the cached position.
    --
    -- vehicleHandle is BaseVehicle:getId(), a short that is only unique within
    -- a session. Safe to hold here because Core.occupants is in-memory and
    -- never persisted. The UUID stays the lease key and is re-checked below in
    -- case the short has been reused.
    local vehicle = nil
    if occupancy.vehicleHandle then
        local candidate = getVehicleById(occupancy.vehicleHandle)
        if candidate and Core.vehicleId(candidate, false) == occupancy.vehicleId then
            vehicle = candidate
        end
    end

    if vehicle then
        return {
            x = vehicle:getX(),
            y = vehicle:getY(),
            z = vehicle:getZ()
        }, vehicle
    end

    -- vehicle is unloaded or gone; fall back to where it was, and say so
    return occupancy.returnTo, nil
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
        Core.logLn("could not resolve a return position for " .. tostring(key))
        return false
    end

    -- Weight is only recomputed here. It matters when driving, and the player
    -- cannot drive from inside, so detecting every item move would cost a lot
    -- for no gameplay difference.
    if vehicle then
        Weight.refresh(vehicle)
    end

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
    -- likely still unloaded at this point, so hand the client what it needs
    -- to do it once the destination chunk has streamed in.
    Core.respond(player, Core.commands.teleport, {
        x = destination.x,
        y = destination.y,
        z = destination.z,
        inside = false,
        reason = reason,
        vehicleHandle = occupancy.vehicleHandle,
        vehicleId = occupancy.vehicleId,
        seat = occupancy.seat,
        standSeat = occupancy.standSeat
    })

    -- Deliberately no "your vehicle is gone" warning here. While the player
    -- was inside, the vehicle almost always unloaded, so from this side an
    -- unloaded vehicle and a destroyed one are indistinguishable and this
    -- fired on every ordinary exit. The client raises it after the teleport
    -- lands and the chunk is loaded, where the question can actually be
    -- answered.
    if not vehicle then
        Core.debugLn("leave: vehicle not loaded here; client will confirm on arrival")
    end

    triggerEvent(Core.events.OnExit, player, reason, owed)
    Core.debugLn(tostring(key) .. " left via " .. tostring(reason))
    return true, owed
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
