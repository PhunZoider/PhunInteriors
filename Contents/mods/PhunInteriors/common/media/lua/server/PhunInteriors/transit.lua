if isClient() then
    return
end
require "PhunInteriors/registry"
-- Core.slotAt, for Transit.rescueStranded. Every boot path happens to load
-- this before a command handler can run, so the require is here to stop that
-- being something a reordering could quietly take away.
require "PhunInteriors/bounds"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Weight = require "PhunInteriors/weight"
local Power = require "PhunInteriors/power"
local Transit = {}
Core.modules.transit = Transit

-- ---------------------------------------------------------------------------
-- Getting in and out.
--
-- There is exactly one way out. Walking out of a doorway, stepping through a
-- hole in the wall, and tripping the leash all call Transit.leave, which puts
-- the player back at the vehicle. No breach handler, no snap back branch.
--
-- They differ only in `via`, which says which side of the box was crossed and
-- so which part of the vehicle to come out at. A declared cab tile is the one
-- exception, and the only tile there is: it asks for a seat instead.
--
-- Leaving is a three step handshake, because no one side can answer the whole
-- question. The server decides where the player goes and which seat they are
-- owed; the client moves them, because vanilla only ever seats a character
-- from a client timed action; then the client reports which vehicle it
-- actually found, which is the first moment anybody can tell an unloaded
-- vehicle from a destroyed one.
-- ---------------------------------------------------------------------------

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
-- Every refusal in Transit.leave is reachable from a square the player is
-- standing still on -- a cab tile, or a square outside the box -- and the
-- leash re-tests it every 250ms for as long as they stay there. Without this,
-- being unable to get out means a wall of halo notes rather than one piece of
-- information.
local function notifyThrottled(player, occupancy, textKey)
    local now = getTimestampMs()
    if occupancy.warnedAt and (now - occupancy.warnedAt) < WARN_INTERVAL_MS then
        return
    end
    occupancy.warnedAt = now
    notify(player, textKey, true)
end

--- Every live zombie within `radius` of a point.
--
-- Collected into a table rather than visited in place, because the caller that
-- acts on the answer MOVES them, and a zombie leaving a square rearranges the
-- list this sweep is walking. That is the same shape of bug as removing an
-- event handler during dispatch: it does not throw, it silently skips the next
-- one, and here it would leave somebody standing in a bubble that reported
-- itself cleared.
local function zombiesWithin(x, y, z, radius)
    local found = {}
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
                            found[#found + 1] = object
                        end
                    end
                end
            end
        end
    end
    return found
end

--- Count zombies near a point. Used for both the entry gate and the exit tax.
local function zombiesNear(x, y, z, radius)
    return #zombiesWithin(x, y, z, radius)
end
Transit.zombiesNear = zombiesNear

-- ---------------------------------------------------------------------------
-- Clearing the ground somebody is about to be standing on.
--
-- Coming out is a teleport, so a tenant cannot see where they are landing and
-- cannot decline to land there. Materialising on top of a crowd is not a risk
-- they took; it is one the mechanic took on their behalf, and no amount of
-- skill answers it. So whatever is standing inside a bubble around the landing
-- point is shoved to the edge of it.
--
-- Deliberately a shove and not a despawn. The crowd is still there, it is
-- still coming, and it is still bigger than the one they left, because the
-- exit tax says so. What the bubble buys is the second or two of warning that
-- somebody walking round the corner on foot would have had.
--
-- Server side, with the rest of the zombie code, for the reason the leash is:
-- the server is the authority, and a client that simply declines to run this
-- must still have it run.
-- ---------------------------------------------------------------------------

--- May a character be put on this square, arriving from `from`?
--
-- isBlockedTo is the wall, window, door and stair test between two ADJACENT
-- squares, which is why the walk below steps one square at a time rather than
-- jumping to the destination: a shove should stop a zombie against a wall, not
-- post it through one.
--
-- isOurSpace is the other refusal, and it is not decoration. An exit inside
-- the interior block -- an admin port, or a vehicle somebody drove onto it --
-- would otherwise shove the neighbourhood into a leased room.
local function shovable(square, from)
    if not square then
        return false
    end
    if square:isSolid() or square:isSolidTrans() then
        return false
    end
    if not square:getFloor() then
        return false
    end
    if from and from:isBlockedTo(square) then
        return false
    end
    if Core.isOurSpace(square:getX(), square:getY(), square:getZ()) then
        return false
    end
    return true
end

--- Move one zombie out to the edge of the bubble, as far as it can get.
local function shoveOne(zombie, cx, cy, radius, spread)
    -- Floored, because the teleportTo overloads are (float, float, INT) and
    -- (int, int, int): handing a float level to a call that wants an int is how
    -- a Kahlua overload resolves to something nobody meant.
    local zz = math.floor(zombie:getZ())
    local dx, dy = zombie:getX() - cx, zombie:getY() - cy
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 0.01 then
        -- Standing on the very square we landed on, so it has no outward
        -- direction of its own to read. Fan them round the compass by index
        -- rather than stacking a whole pile on one bearing.
        local angle = (spread % 8) * math.pi / 4
        dx, dy, length = math.cos(angle), math.sin(angle), 1
    end
    dx, dy = dx / length, dy / length

    local cell = getCell()
    local tx = math.floor(cx + dx * (radius + 1))
    local ty = math.floor(cy + dy * (radius + 1))
    local x, y = math.floor(zombie:getX()), math.floor(zombie:getY())
    local square = cell:getGridSquare(x, y, zz)
    local moved = false

    -- The Manhattan distance from inside a circle to a point on its edge is at
    -- most twice the radius, and every step below closes it, so this cannot
    -- spin however the geometry comes out.
    for _ = 1, 2 * radius + 4 do
        if x == tx and y == ty then
            break
        end
        -- One cardinal step, longer axis first. Cardinal rather than diagonal
        -- because isBlockedTo asks about a shared edge, and two squares that
        -- meet at a corner do not have one.
        local sx, sy = x, y
        if math.abs(tx - x) >= math.abs(ty - y) then
            sx = x + (tx > x and 1 or -1)
        else
            sy = y + (ty > y and 1 or -1)
        end
        local step = cell:getGridSquare(sx, sy, zz)
        if not shovable(step, square) then
            break
        end
        x, y, square = sx, sy, step
        moved = true
    end

    if not moved then
        return false
    end

    -- The same call and the same half tile the player teleport uses, so both
    -- ends of a port land the same way. teleportTo floors it either way; the
    -- offset is there so it stays centred should that ever change.
    zombie:teleportTo(x + 0.5, y + 0.5, zz)
    return true
end

--- Clear a bubble of `radius` squares around a point. Returns how many moved.
--
-- A zombie with nowhere to go is left where it is, which is the honest answer:
-- the bubble is a best effort and never a guarantee. Boxed in on every side,
-- there is nowhere to put it that is not a worse lie than leaving it.
function Transit.shoveZombies(x, y, z, radius)
    radius = tonumber(radius) or 0
    if radius <= 0 then
        -- The sandbox option turned off. One place decides that, and it is
        -- here, so no caller has to remember to ask first.
        return 0
    end
    z = math.floor(z)

    local crowd = zombiesWithin(x, y, z, radius)
    local moved = 0
    for index, zombie in ipairs(crowd) do
        if shoveOne(zombie, x, y, radius, index) then
            moved = moved + 1
        end
    end

    -- Silent when there was nothing to do, which on an ordinary exit is most
    -- of the time. A line that fires when nothing happened is how a log
    -- becomes something nobody reads.
    if #crowd > 0 then
        Core.debugLn(string.format("shove: %d of %d zombie(s) cleared from %d squares around %d,%d,%d", moved, #crowd,
            radius, math.floor(x), math.floor(y), math.floor(z)))
    end
    return moved
end

--- Can this player enter this vehicle right now?
-- Returns true, or false plus a translation key.
function Transit.canEnter(player, vehicle)
    if not player or not vehicle then
        return false, "IGUI_PhunInteriors_NoVehicle"
    end

    -- Only that it has rooms at all. WHICH room, and whether that room's own
    -- requires are satisfied, is Slots.acquire's decision -- a vehicle may
    -- fail one room's demands and still be entitled to another, so a single
    -- answer here would refuse entries that should succeed.
    if not Core.vehicleHasRooms(vehicle) then
        return false, "IGUI_PhunInteriors_WrongVehicle"
    end

    -- Stepping from a seat into the interior is fine at speed; catching a
    -- moving vehicle from outside, or abandoning the wheel of one, is not.
    local mayMove, why = Core.vehicleMotionAllows(vehicle, player)
    if not mayMove then
        return false, why
    end

    if Core.settings.EntryBlockedByZombies then
        local radius = Core.settings.EntryZombieRadius or 4
        if zombiesNear(vehicle:getX(), vehicle:getY(), vehicle:getZ(), radius) > 0 then
            return false, "IGUI_PhunInteriors_ZombiesTooClose"
        end
    end

    return true
end

--- Move the player into a leased slot and start the leash watching them.
--
-- Everything from here down is the same job whoever asked: check the room can
-- actually be stood in, open the capture window if this slot has never been
-- used, write the occupancy, send the teleport. What differs between a vehicle
-- entry and an admin port is all above this -- which lease, and what the
-- player is owed on the way back out -- so the caller hands those in as the
-- occupancy fields it wants set.
--
-- Factored out when the admin tool arrived. Two copies of the world-bounds
-- guard and the grace window would have drifted, and the grace window in
-- particular is load bearing: it has to outlast the client's chunk-streaming
-- hold or the leash ejects a player who is still in mid-teleport.
-- How many players are inside a room right now.
--
-- Kept alongside Core.occupants rather than derived from it, because the
-- question "is anybody inside at all" is asked sixty times a second by the
-- leash and the answer is almost always no. Deriving it needs a pairs() walk,
-- and PZ's sandbox has no next() to make that a one-liner.
--
-- It cannot drift, because setOccupancy is the only thing that writes the
-- table and it counts the transition rather than the value -- setting the same
-- occupancy twice, or clearing an empty slot, both leave the count alone.
local occupants = 0

--- Where this player was standing when they went in, or nil.
--
-- Read back defensively rather than trusted: it is durable state that has
-- survived restarts and mod versions, so a field that is missing or is not a
-- number means the record is from something else and the caller should behave
-- as though there were none.
function Transit.entranceOf(player)
    local md = player and player:getModData()
    local at = md and md[Core.consts.entranceKey]
    if type(at) ~= "table" then
        return nil
    end
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if not x or not y then
        return nil
    end
    return {x = x, y = y, z = z or 0}
end

--- The only way the entrance is written, and it hangs off the only way
--- occupancy is written for exactly the reason that one exists.
--
-- The invariant is "a stored entrance exists precisely while the player has an
-- occupancy", and the cheapest way to make that structurally true is to give
-- it no lifecycle of its own.
-- Deliberately not guarded against a player with no getModData. There is no
-- such thing in game, and a guard here would turn "the entrance is not being
-- stored" into silence -- which is the failure this mod keeps meeting from the
-- other end. A test fixture that wants to reach this grows a getModData.
local function setEntrance(player, at)
    local md = player:getModData()
    md[Core.consts.entranceKey] = at and {x = at.x, y = at.y, z = at.z or 0} or nil
end

--- The only way occupancy is written. Every path through it, no exceptions.
--
-- There are three: entering, recovering a player who logged in already inside,
-- and leaving. They used to write Core.occupants directly, which was fine
-- while nothing else depended on the table's shape -- but a count maintained
-- in two of the three places would fail open, and failing open here means a
-- recovered tenant who is not contained at all.
--
-- It also carries the durable entrance position, and the asymmetry between the
-- two branches below is the whole of the design. Setting writes one only when
-- the occupancy CARRIES one, because Transit.recover sets an occupancy for a
-- player who is standing INSIDE the room -- reading their position there would
-- store the interior square as the place to escape to, and the fallback would
-- teleport them back into the room they are trying to leave. Clearing is
-- unconditional, because leaving is leaving.
function Transit.setOccupancy(player, occupancy)
    local key = Core.playerKey(player)
    if not key then
        return
    end
    local had = Core.occupants[key] ~= nil
    Core.occupants[key] = occupancy
    if occupancy and not had then
        occupants = occupants + 1
    elseif not occupancy and had then
        occupants = occupants - 1
    end

    if not occupancy then
        setEntrance(player, nil)
    elseif occupancy.enteredFrom then
        setEntrance(player, occupancy.enteredFrom)
    end
end

--- Is anybody inside a room? One integer compare.
function Transit.anyoneInside()
    return occupants > 0
end

local function placeInside(player, assignment, occupancy)
    local room = Core.rooms[assignment.room]
    local spawn = Core.slotSpawn(room, assignment.index)
    if not spawn then
        Core.logLn("leased " .. tostring(assignment.room) .. "#" .. tostring(assignment.index) ..
            " but it has no position; refusing rather than teleporting nowhere")
        notify(player, "IGUI_PhunInteriors_NoFreeRoom", true)
        return false
    end

    -- A room points at coordinates that only exist if the map providing
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
            tostring(assignment.room), tostring(assignment.index),
            tostring(spawn.x), tostring(spawn.y),
            tostring(grid:getMinX()), tostring(grid:getMaxX()),
            tostring(grid:getMinY()), tostring(grid:getMaxY())))
        Slots.release(occupancy.vehicleId, "destination not in this world")
        notify(player, "IGUI_PhunInteriors_RoomNotInWorld", true)
        return false
    end

    -- If nobody has ever had this room, it is pristine, and the leash will
    -- capture its blueprint as soon as it sees the player actually inside it.
    -- That is the only moment the room is both loaded and untouched: the
    -- chunk is not loaded here, and it stops being pristine the moment the
    -- tenant moves a chair.
    local pristine = Slots.markUsed(assignment.room, assignment.index)

    occupancy.room = assignment.room
    occupancy.index = assignment.index
    -- Give the teleport time to land before the leash starts judging. Must
    -- outlast the client's HOLD_TICKS window, or the leash ejects a player
    -- who is still waiting for the destination chunk to stream in.
    occupancy.graceUntil = getTimestampMs() + 6000
    occupancy.captureSlot = pristine or nil
    occupancy.captureTries = 0
    occupancy.scrubTries = 0
    occupancy.enteredAt = Core.now()

    -- Where they are standing right now, which is the last moment anybody can
    -- ask: the next line writes the occupancy and the one after teleports them
    -- into the room.
    --
    -- Captured here rather than in the three entry paths because here is the
    -- one place all of them pass through, and because the fourth caller wants
    -- it too: Transit.arrived re-enters a player whose cab turned out to be
    -- full, and they went in from beside the vehicle they are now standing
    -- next to. Transit.recover is deliberately NOT a caller of this function.
    occupancy.enteredFrom = {
        x = player:getX(),
        y = player:getY(),
        z = player:getZ()
    }

    Transit.setOccupancy(player, occupancy)

    Core.respond(player, Core.commands.teleport, {
        x = spawn.x,
        y = spawn.y,
        z = spawn.z,
        inside = true
    })
    return true
end

--- Put a player inside. Server authoritative; the client only does the move.
function Transit.enter(player, vehicle, seat, standSeat)
    local ok, refusal = Transit.canEnter(player, vehicle)
    if not ok then
        notify(player, refusal, true)
        return false
    end

    local vehicleId = Core.vehicleId(vehicle, true)

    -- Stamped on the vehicle the first time it is given a room and never
    -- cleared, so a vehicle carrying it with no lease has lost one -- nearly
    -- always to a reclaim while nobody was using it. Its owner is about to be
    -- handed an empty room and should be told why, rather than conclude the mod
    -- ate their things. Not the UUID: that is written a line up, before
    -- allocation, so a vehicle refused its very first room carries one too.
    local vmd = vehicle:getModData()
    local lostRoom = vmd[Core.consts.leasedKey] and not Slots.find(vehicleId)

    -- The vehicle, not a room: which room it ends up in is an allocation
    -- decision that depends on what else is free, and each candidate room
    -- tests its own requires against this vehicle on the way past.
    local assignment, reason, dirty = Slots.acquire(vehicleId, vehicle)
    if not assignment then
        notify(player, reason, true)
        return false
    end

    -- Somebody has claimed this room and it is not this player.
    --
    -- Checked HERE rather than in canEnter, because canEnter runs before
    -- allocation and there is no slot to ask about yet. And before
    -- Slots.touch below, because a refused entry must not renew the lease --
    -- lastSeen is what the reclaim measures, so touching it here would keep a
    -- room alive on the strength of entries that never happened.
    --
    -- The lease is left exactly as it was. The claim is over the SLOT, not
    -- over the vehicle's right to it: whoever holds the lease still holds it,
    -- and will be let back in the moment the claim goes.
    --
    -- Nothing in the engine would have stopped this. The whole enforcement
    -- surface for a claimed square is BaseVehicle.isExitBlocked2 -- getting
    -- out of a seat onto one -- so a teleport lands on it unopposed and the
    -- tenant simply stands in somebody's safehouse. See the API table.
    local trespass = Slots.trespassOn(assignment.room, assignment.index, player)
    if trespass then
        notify(player, "IGUI_PhunInteriors_Trespassing", true)
        Core.debugLn(string.format("refused %s entry to %s#%s: claimed by %s",
            tostring(Core.playerKey(player)), assignment.room, tostring(assignment.index),
            tostring(trespass:getOwner())))
        return false
    end

    vmd[Core.consts.leasedKey] = true
    if lostRoom then
        notify(player, "IGUI_PhunInteriors_RoomReclaimed", true)
    end

    -- A slot handed over straight from quarantine still holds the last
    -- tenant's mess. Try to clean it now: if another player is in a
    -- neighbouring slot the chunk is already loaded and this succeeds, and
    -- nobody ever sees it. Otherwise the leash finishes the job on arrival,
    -- which is the first moment the chunk is guaranteed to exist.
    local scrubOnArrival = false
    if dirty then
        local Scrub = require "PhunInteriors/scrub"
        local cleaned, why = Scrub.slot(assignment.room, assignment.index)
        if not cleaned then
            Core.debugLn(string.format("%s#%s still dirty (%s); scrubbing on arrival",
                tostring(assignment.room), tostring(assignment.index), tostring(why)))
            scrubOnArrival = true
        end
    end
    Slots.touch(vehicleId)

    -- Who used it last, for the admin lease list
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

    -- The vehicle is loaded and in hand right here, and will not be again
    -- until the tenant comes back out. Settle whatever the room owes and take
    -- a true battery reading for it to spend.
    Power.syncVehicle(vehicleId, vehicle)

    local key = Core.playerKey(player)

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

    -- Snapshot the crowd we are walking away from. The exit tax grows this
    -- while the player is inside, so waiting out the night costs something.
    local snapshot = 0
    if Core.settings.ExitTax then
        snapshot = zombiesNear(vehicle:getX(), vehicle:getY(), vehicle:getZ(), 15)
    end

    -- Getting the player out of the seat happens client side, with the
    -- teleport, because vanilla only ever exits a vehicle from a client timed
    -- action. The seat is already captured above.
    if not placeInside(player, assignment, {
        vehicleId = vehicleId,
        -- session-scoped handle, for the live lookup in resolveReturn
        vehicleHandle = vehicle:getId(),
        seat = requestedSeat,
        standSeat = requestedDoor,
        scrubOnArrival = scrubOnArrival or nil,
        zombieSnapshot = snapshot,
        returnTo = {
            x = vehicle:getX(),
            y = vehicle:getY(),
            z = vehicle:getZ()
        }
    }) then
        return false
    end

    triggerEvent(Core.events.OnEnter, player, vehicle, assignment)
    Core.debugLn(tostring(key) .. " entered " .. assignment.room .. "#" .. assignment.index ..
        " from seat " .. tostring(requestedSeat) .. ", door " .. tostring(requestedDoor))
    return true
end

-- ---------------------------------------------------------------------------
-- Entering a world object.
--
-- Simpler than a vehicle in every respect that made the vehicle path hard,
-- and for one reason: A TENT DOES NOT MOVE. So there is no tracker, no live
-- sweep for a reloaded handle, no motion rule, no seat to vacate or return to
-- and no cab landing. The position stored on the lease is frozen truth by
-- construction rather than by the load rule, which means the exit is the admin
-- port's exit with a different address on it.
--
-- What is NOT simpler is identity, and it is handled in holders.lua: the id
-- lives inside modData.movableData because vanilla drops a top level key when
-- some classes are picked up and keeps it for others, and a tent is both
-- classes at once.
-- ---------------------------------------------------------------------------

--- Put a player inside the room leased to the object on this square.
function Transit.enterObject(player, object, anchor)
    if not player or not object then
        notify(player, "IGUI_PhunInteriors_NoVehicle", true)
        return false
    end

    local key = Core.playerKey(player)
    if Core.occupants[key] then
        return false
    end

    if not Core.objectHasRooms(object) then
        -- Not the vehicle-flavoured key. "This vehicle has no interior", said
        -- about a tent, is how this refusal was first reported.
        notify(player, "IGUI_PhunInteriors_WrongHolder", true)
        return false
    end

    if Core.settings.EntryBlockedByZombies then
        local radius = Core.settings.EntryZombieRadius or 4
        if zombiesNear(anchor.x, anchor.y, anchor.z or 0, radius) > 0 then
            notify(player, "IGUI_PhunInteriors_ZombiesTooClose", true)
            return false
        end
    end

    -- Minted here rather than on placement, so an object nobody has ever used
    -- carries nothing of ours and a world full of tents costs nothing.
    local holderId = Core.objectKey(Core.objectId(object, true))

    local assignment, reason, dirty = Slots.acquire(holderId, object)
    if not assignment then
        notify(player, reason, true)
        return false
    end

    -- Same refusal as the vehicle path, and before Slots.touch for the same
    -- reason: a refused entry must not renew the lease.
    local trespass = Slots.trespassOn(assignment.room, assignment.index, player)
    if trespass then
        notify(player, "IGUI_PhunInteriors_Trespassing", true)
        return false
    end

    local scrubOnArrival = false
    if dirty then
        local Scrub = require "PhunInteriors/scrub"
        local cleaned = Scrub.slot(assignment.room, assignment.index)
        scrubOnArrival = not cleaned
    end
    Slots.touch(holderId)

    assignment.lastUser = key
    -- Where they come back out. The anchor square rather than the tile that
    -- was clicked, so leaving by one corner and re-entering by another does
    -- not walk the return position around the tent.
    assignment.lastKnownVehiclePos = {
        x = anchor.x,
        y = anchor.y,
        z = anchor.z or 0
    }

    -- No battery, and no generator bound to it yet -- power for a world object
    -- holder is a separate piece. Say full so a lit room is lit, and clear the
    -- ledger for the same reason the admin port does: nothing settles a debt
    -- that has nothing to settle it against, and left to accumulate it would
    -- eventually darken the room for no visible reason.
    assignment.batteryKnown = 1
    assignment.fuelOwed = 0

    if not placeInside(player, assignment, {
        vehicleId = holderId,
        -- Reuses the admin port's arrival rule, and means the same thing: no
        -- seat to return to, nothing to weigh, and no handshake that could end
        -- in a false "your vehicle is gone".
        noVehicle = true,
        seat = -1,
        standSeat = -1,
        scrubOnArrival = scrubOnArrival or nil,
        zombieSnapshot = 0,
        returnTo = assignment.lastKnownVehiclePos
    }) then
        return false
    end

    -- Now it is somebody's, so it may not be packed away. Written here because
    -- here is the one moment the server is certain the object is loaded: the
    -- player was standing next to it a line ago.
    Core.setObjectLock(object, "occupied")

    Core.debugLn(string.format("%s entered %s#%s through %s", tostring(key), assignment.room,
        tostring(assignment.index), tostring(Core.moveableItemOf(object))))
    return true
end

--- Re-assert the pickup lock on the object holding this lease.
--
-- Called when the tenant lands back on top of it, which is the only moment
-- after an exit that the object is known to be loaded -- the same reasoning
-- that puts the weight and the battery on the arrival report rather than on a
-- timer, and it rides the same report.
--
-- The object is resolved from the POSITION rather than from an identity the
-- client sent, and then its own id is checked against the lease before
-- anything is written. Otherwise a second tent pitched where the first one
-- stood would be locked on behalf of somebody else's room.
function Transit.refreshHolderLock(leaseKey, at)
    if not at or Core.holderKind(leaseKey) ~= "object" then
        return false
    end
    local object = Core.boundObjectAt(at.x, at.y, at.z or 0)
    if not object then
        Core.debugLn("holder lock: nothing bound at " .. tostring(at.x) .. "," .. tostring(at.y) ..
                         "; the lock stands as it was")
        return false
    end
    if Core.objectKey(Core.objectId(object, false)) ~= leaseKey then
        Core.logLn("holder lock: the object at " .. tostring(at.x) .. "," .. tostring(at.y) ..
                       " does not hold that lease; leaving it alone")
        return false
    end

    local reason = Slots.lockReason(leaseKey)
    Core.setObjectLock(object, reason)
    Core.debugLn("holder lock: " .. tostring(leaseKey) .. " is now " .. (reason or "free to be packed away"))
    return true
end

-- ---------------------------------------------------------------------------
-- The admin port.
--
-- A room designer wants to stand in room number nine. Doing that through the
-- front door means spawning a vehicle of the right script, parking it, getting
-- in, and accepting whatever the allocator hands out -- which for a room low
-- in the specificity order may be nothing at all.
--
-- So this leases the named room to the admin directly. What it deliberately
-- does NOT do is invent a second way of being inside a room: the lease is a
-- real lease, the occupancy is a real occupancy, the leash watches them, the
-- capture fires, a quarantined slot is scrubbed on arrival. Everything a room
-- does to a tenant, it does to an admin standing in it, which is the entire
-- point of testing from in here rather than from a debug teleport.
--
-- The one thing there is no vehicle for is the vehicle. The lease is keyed on
-- the admin rather than a UUID, and the position it would have stored for the
-- van is where the admin was standing when they pressed the button -- which is
-- exactly where they want to come back to.
-- ---------------------------------------------------------------------------

--- Port an admin into a named room, leasing it to them.
--
-- index nil takes the next free slot. Returns true, or false plus a reason
-- in plain English -- this one is only ever read by an admin, so it says what
-- happened rather than naming a translation key.
function Transit.adminEnter(player, roomId, index)
    if not player then
        return false, "no player"
    end
    local key = Core.playerKey(player)
    if Core.occupants[key] then
        -- Refusing beats silently moving them: the occupancy they already have
        -- owns a lease and a return position, and quietly replacing it would
        -- strand both.
        return false, "you are already inside a room; leave it first"
    end

    local vehicleId = Core.adminKey(player)
    local assignment, refusal, dirty = Slots.acquireIn(vehicleId, roomId, index)
    if not assignment then
        return false, refusal
    end

    -- An admin is refused a claimed room like anybody else, and deliberately
    -- so. There is no exemption written here because vanilla already has one:
    -- playerAllowed passes anybody whose role carries CanGoInsideSafehouses,
    -- which is the same rule that lets them into every other safehouse in the
    -- world. An admin without it removes the claim through vanilla's own admin
    -- tools -- safehouses are vanilla's, and so is the escape hatch.
    --
    -- Plain English rather than a translation key: adminEnter's refusals go
    -- back as console lines, not as halo notes.
    local trespass = Slots.trespassOn(roomId, assignment.index, player)
    if trespass then
        return false, string.format("%s#%s is claimed as a safehouse by %s, and you are not on it",
            roomId, tostring(assignment.index), tostring(trespass:getOwner()))
    end

    -- Where they were standing. This is the lease's "where is the vehicle",
    -- and every exit path reads it, so an admin who ports in from the middle
    -- of a field comes back to the middle of that field.
    assignment.lastKnownVehiclePos = {
        x = player:getX(),
        y = player:getY(),
        z = player:getZ()
    }
    assignment.lastUser = key
    -- A room with a generator reads the battery it is billed against through
    -- the ledger, and there is no battery here. Say full, so the lights come
    -- on: an admin inspecting a room they are building should see it lit, and
    -- a dark room would read as a fault in the room rather than as an absent
    -- van.
    assignment.batteryKnown = 1
    -- And clear what the last visit banked. Nothing ever settles this debt --
    -- there is no battery to take it off -- so left alone it accumulates
    -- across visits until the projected charge goes negative and the room a
    -- designer is standing in goes dark for no reason they can see.
    assignment.fuelOwed = 0

    local scrubOnArrival = false
    if dirty then
        local Scrub = require "PhunInteriors/scrub"
        local cleaned = Scrub.slot(assignment.room, assignment.index)
        scrubOnArrival = not cleaned
    end

    if not placeInside(player, assignment, {
        vehicleId = vehicleId,
        noVehicle = true,
        seat = -1,
        standSeat = -1,
        scrubOnArrival = scrubOnArrival or nil,
        zombieSnapshot = 0,
        returnTo = assignment.lastKnownVehiclePos
    }) then
        return false, "that room has nowhere to put you; check the log"
    end

    Core.logLn(string.format("%s ported into %s#%s%s", tostring(key),
        assignment.room, tostring(assignment.index),
        dirty and " (quarantined, scrubbing)" or ""))
    return true, string.format("%s#%s", assignment.room, tostring(assignment.index))
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

    -- A push only ever happens because somebody is driving this thing, which
    -- means it is loaded and its battery is readable. That makes this the
    -- cheapest settlement point we have, and it costs nothing to take: no
    -- sweep, no timer, no separate hook.
    Power.syncVehicle(vehicleId, vehicle)

    Core.debugLn(string.format("tracked %s to %d,%d,%d (handle %s)",
        tostring(vehicleId), vehicle:getX(), vehicle:getY(), vehicle:getZ(),
        tostring(handle)))
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
        -- And it must still be in the world: a vehicle scrapped a moment ago
        -- can still answer to its id, and a torn down vehicle is nowhere to
        -- put anybody. removal.lua banks its position before it goes.
        if candidate and not candidate:isRemovedFromWorld()
            and Core.vehicleId(candidate, false) == occupancy.vehicleId then
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

--- The last resort: where this player came in from.
--
-- Only ever reached when every answer about the HOLDER has come back empty --
-- the vehicle is not loaded, and there is no lease to read a position off
-- because it was reclaimed, released or lost while they were inside. Before
-- this existed that combination refused the exit and left the tenant standing
-- in the room needing an admin to evict them.
--
-- Validated, because this is the one return position that can be genuinely
-- STALE. The other two describe a holder that cannot have moved; this one is
-- wherever the player happened to be standing, possibly months ago, and a
-- wrong position does not fail loudly -- it teleports somebody into geometry
-- and looks deliberate. The meta grid check is the same one placeInside makes
-- and is the strongest available here, because the destination chunk is not
-- loaded: it catches the coordinates not existing in this world at all, which
-- is what a map removed from the mod list leaves behind. It cannot catch a
-- wall somebody built there since, and nothing server side can.
--
-- Says so in the log, but only once per visit. A fallback that fires silently
-- is how you stop noticing the thing in front of it is broken -- and a line
-- that repeats four times a second is how a log stops being read at all. Both
-- matter here, because every refusal in Transit.leave is reachable from a
-- square the player is standing still on and the leash re-tests it every
-- 250ms. That is what the occupancy flag is for; rescueStranded passes none,
-- because it runs once on login and there is nothing to repeat.
function Transit.fallbackReturn(player, occupancy)
    local at = Transit.entranceOf(player)
    if not at then
        return nil
    end

    local function sayOnce(field, text)
        if occupancy then
            if occupancy[field] then
                return
            end
            occupancy[field] = true
        end
        Core.logLn(text)
    end

    local grid = getWorld() and getWorld():getMetaGrid()
    if grid and not grid:isValidSquare(at.x, at.y) then
        sayOnce("warnedEntranceGone", string.format(
            "%s has no holder to come out at, and the square they went in from "
            .. "(%s,%s) is not in this world; refusing rather than teleporting there",
            tostring(Core.playerKey(player)), tostring(at.x), tostring(at.y)))
        return nil
    end

    sayOnce("saidUsingEntrance", string.format(
        "%s has no holder to come out at; falling back to where they went in, %s,%s,%s",
        tostring(Core.playerKey(player)), tostring(at.x), tostring(at.y), tostring(at.z)))
    return at
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
--
-- Behind all of them sits the entrance position, which is last on purpose. It
-- is the one answer that does not describe the holder at all, so preferring it
-- would put a tenant back on the kerb their van has since been driven away
-- from -- the exact failure the tracker exists to prevent.
local function resolveReturn(player, occupancy)
    local assignment = Slots.find(occupancy.vehicleId)

    -- A holder with no vehicle: an admin port, or a world object such as a
    -- tent. Its stored position is where the admin stood or where the object
    -- is, so it is both the answer and the only answer -- sweeping 49 squares
    -- for a vehicle that was never there could only ever find somebody else.s.
    if occupancy.noVehicle then
        return (assignment and assignment.lastKnownVehiclePos) or occupancy.returnTo
            or Transit.fallbackReturn(player, occupancy), nil
    end

    local vehicle = liveVehicle(occupancy, assignment)

    if vehicle then
        return {
            x = vehicle:getX(),
            y = vehicle:getY(),
            z = vehicle:getZ()
        }, vehicle
    end

    return (assignment and assignment.lastKnownVehiclePos) or occupancy.returnTo
        or Transit.fallbackReturn(player, occupancy), nil
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

--- Take a player out, or say why not.
--
-- reason is one of "cab", "leash", "breach", "admin".
--
-- `via` is the edge of the box they crossed -- "north", "south", "east",
-- "west" -- or nil when there is no edge to name: a roof, a room that has gone
-- out from under them, or a request through the context menu rather than a
-- walk. It is looked up in room.landing, which answers one of three ways:
--
--   "cab"          into a seat, any seat
--   an area name   on the ground at that part of the vehicle, eg "TruckBed"
--   nothing        beside the vehicle, which is what every exit did before
--
-- Nothing here resolves an area or a seat. The vehicle is essentially never
-- loaded at this point -- its chunk unloaded the moment its owner went inside
-- -- so the answer travels down with the teleport and the client asks the real
-- vehicle once it has streamed in. That is the arrival half of a handshake
-- that already exists rather than a new one.
--
-- Returns true plus the exit tax on success, or false plus a short reason.
-- The reason matters because admin evict reports it: without one, every
-- refusal read as "not inside a room", which is a lie when the truth is
-- "inside, but the van they are riding in is doing forty".
function Transit.leave(player, reason, via)
    local key = Core.playerKey(player)
    local occupancy = Core.occupants[key]
    if not occupancy then
        return false, "not inside a room"
    end

    local destination, vehicle = resolveReturn(player, occupancy)
    if not destination then
        -- Nothing to fall back on. Refusing silently strands the player with a
        -- dead exit tile and no idea why, so say so; the lease survives, and
        -- an admin can evict them.
        Core.logLn("could not resolve a return position for " .. tostring(key))
        notifyThrottled(player, occupancy, "IGUI_PhunInteriors_VehicleGone")
        return false, "their vehicle cannot be located"
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
    if vehicle and Core.vehicleIsMoving(vehicle) then
        seatOut = freeSeat(vehicle, occupancy.seat)
        if not seatOut then
            Core.debugLn(tostring(key) .. " tried to leave a moving vehicle with no free seat")
            notifyThrottled(player, occupancy, "IGUI_PhunInteriors_VehicleMoving")
            return false, "their vehicle is moving and every seat is taken"
        end
    end

    -- Where on the vehicle they come out, resolved client side.
    --
    -- A cab exit asks for a seat and does not care which, so it deliberately
    -- passes no preference: the first free one is the cab exit working. That
    -- also means where they got IN no longer decides where they come out --
    -- the door does. Somebody who climbed in from the driver's seat and walks
    -- out of the north wall lands at the back of the van, which is what the
    -- room is telling them will happen.
    --
    -- The seat can be refused -- every one taken -- and only the client can
    -- see that, because the vehicle is not loaded here. So the cab exit is a
    -- REQUEST, and Transit.arrived puts them back in the room if it failed.
    -- NOT `destination`. That name is taken, eighty lines up, by the position
    -- resolveReturn worked out -- and redeclaring it here quietly replaced a
    -- table with a string, so every exit sent a teleport to nil,nil and the
    -- client died on `nil + 0.5`. Nothing caught it: LuaJIT parses a shadowed
    -- local happily and the specs do not reach Transit.leave.
    -- Nothing for an admin port. There is no vehicle, so there is no part of
    -- one to come out at and no seat to be put in -- the same reason it files
    -- no arrival paperwork. Without this the payload carried a landing the
    -- client could never resolve, and a cab exit would have set a flag that
    -- Transit.arrived is never reached to act on.
    --
    -- Core.relativeFor is the whole of it: the room says which edge faces the
    -- holder's front, the leash says which edge was crossed, and the answer is
    -- "front", "rear", "left", "right" or nil. Nothing here knows a vehicle
    -- part name, which is the point -- the room used to name one and could only
    -- do it by being a vehicle.
    local leftBy = (via and not occupancy.noVehicle) and Core.rooms[occupancy.room]
    local relative = leftBy and Core.relativeFor(leftBy, via) or nil
    -- Only the front edge can be a cab, so this is one comparison rather than a
    -- lookup. A room with cab set and no front never gets here, and says so at
    -- registration.
    local cabExit = (relative == "front") and leftBy.cab == true
    local toward = (not cabExit) and relative or nil

    -- One survey of the room, and both of its answers are only available here.
    --
    -- Weight is recomputed on the way out and nowhere else. It matters when
    -- driving, and the player cannot drive from inside, so watching every item
    -- move would cost a great deal for no gameplay difference. Applying it is
    -- a separate question -- the vehicle is almost never loaded at this point
    -- -- so that is deferred to the arrival report.
    --
    -- The tally is what says whether a holder that can be carried off may be
    -- packed away, and it is banked for the same reason and at the same
    -- moment: the room is loaded right now because the player is standing in
    -- it, and a moment from now it will not be. See Slots.lockReason.
    --
    -- The survey now runs for EVERY holder, where the weight half used to be
    -- skipped when there was no vehicle to charge. It is no longer a
    -- measurement taken for nobody -- a tent reads the tally. Weight is still
    -- only applied where there is something to apply it to, which leaves a
    -- world object interior with no carry cost at all: a real hole rather than
    -- an oversight, and the reason a tent room has to be kept small by design.
    local interiorWeight, interiorCount = Weight.surveySlot(occupancy.room, occupancy.index)
    local lease = Slots.find(occupancy.vehicleId)
    if lease then
        lease.contents = interiorCount
    end
    if occupancy.noVehicle then
        interiorWeight = 0
    elseif vehicle then
        Weight.apply(vehicle, interiorWeight)
    end

    -- One last read of the generator while the room is still loaded, for the
    -- same reason as the weight: the player is standing in it now and will not
    -- be a moment from now. The debt this banks is settled against the battery
    -- on the arrival report, or by the tracker if somebody drives it first.
    Power.syncRoom(occupancy.room, occupancy.index, occupancy.vehicleId)

    -- What is still owed once the player confirms they landed. Applying the
    -- mass needs the vehicle loaded, and it is not loaded here -- it will be
    -- the moment the player arrives on top of it, so this waits for their
    -- report rather than for a timer to notice.
    --
    -- A holder with no vehicle has nothing outstanding and nothing to look
    -- for, so it files no paperwork. Without this the client would search the destination
    -- for a vehicle, find none, and be told its vehicle is gone -- which for
    -- somebody who arrived on foot is both true and useless.
    if not occupancy.noVehicle then
        pendingArrivals[key] = {
            vehicleId = occupancy.vehicleId,
            -- both nil when they were applied above, because the vehicle
            -- happened to be loaded already
            weight = (not vehicle) and interiorWeight or nil,
            -- Enough to put them back if the cab turns out to be full. Kept
            -- here rather than looked up again, because by the time the report
            -- lands the occupancy is gone -- the lease is not, which is what
            -- makes going back in cheap.
            cab = cabExit or nil,
            room = cabExit and occupancy.room or nil,
            index = cabExit and occupancy.index or nil,
            expires = getTimestampMs() + ARRIVAL_TIMEOUT_MS
        }
    elseif Core.holderKind(occupancy.vehicleId) == "object" then
        -- A world object files a much smaller version of the same paperwork,
        -- and for the same reason the vehicle does: the thing the server needs
        -- to touch is not loaded here, and the player arriving is what loads
        -- it. There is nothing to weigh and no seat to return to -- the only
        -- outstanding job is re-asserting the pickup lock on the tent they are
        -- about to be standing on.
        --
        -- An admin port files nothing, still. There is no object there either.
        pendingArrivals[key] = {
            holder = occupancy.vehicleId,
            at = destination,
            expires = getTimestampMs() + ARRIVAL_TIMEOUT_MS
        }
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

    Transit.setOccupancy(player, nil)
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
        -- Nothing to rejoin when nobody drove here.
        rejoin = not occupancy.noVehicle,
        -- ...but a world object holder still owes an arrival report, because
        -- its tent has to be reached to be unlocked. Separate from `rejoin`,
        -- which means "look for a vehicle and climb into it" and would send
        -- this player hunting for one that was never there.
        report = (pendingArrivals[key] ~= nil) or nil,
        -- A cab exit takes any seat, so it sends no preference and lets the
        -- client pick. Otherwise it is the seat they are owed: forced when the
        -- vehicle is moving, else the one they arrived in.
        seat = (not cabExit) and (seatOut or occupancy.seat) or nil,
        cab = cabExit or nil,
        -- Which part of the holder to come out at -- "front", "rear", "left",
        -- "right" -- or nil for "anywhere beside it". The client turns that
        -- into a real position, because only the client has the vehicle.
        toward = toward,
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
function Transit.arrived(player, handle, seated)
    local key = Core.playerKey(player)
    local record = pendingArrivals[key]
    if not record then
        -- Duplicate report, or one that outlived its window. Nothing owed.
        return false
    end
    pendingArrivals[key] = nil

    -- Clear the ground first, before anything below decides to send them back
    -- inside or to tell them their vehicle is gone.
    --
    -- Here rather than in Transit.leave, and this is the same split the weight
    -- and the power ledger already live on: when leave ran, the destination
    -- chunk was unloaded, so there were no zombies there to move -- there were
    -- no zombies there at all, because a zombie only exists as an object in a
    -- loaded chunk. The player arriving is what loads it, and this report is
    -- the first moment the server knows they have.
    Transit.shoveZombies(player:getX(), player:getY(), player:getZ(), Core.settings.ExitShoveRadius)

    -- A world object holder. Nothing was driven here, nothing is owed against
    -- a battery and there is no seat to be refused, so the whole report is
    -- "the tent is loaded again, decide whether it may be packed away". The
    -- handle the client sent is ignored: it was looking for a vehicle and
    -- there is none, and the object is resolved from the position instead.
    if record.holder then
        Transit.refreshHolderLock(record.holder, record.at)
        return true
    end

    -- The cab exit is the one way out that can fail, and it can only fail out
    -- here: whether a seat is free is a question about a vehicle that was not
    -- loaded when they left. So they are already standing next to it, and the
    -- honest answer is to put them back where they were.
    --
    -- Cheap, because only the occupancy was torn down. The lease is untouched
    -- -- Slots.touch renewed it on the way out -- so this re-enters the same
    -- slot rather than allocating anything, and the capture and scrub windows
    -- are simply not reopened: this room has been stood in already.
    if record.cab and not seated then
        local assignment = Slots.find(record.vehicleId)
        if assignment and assignment.room == record.room and assignment.index == record.index then
            Core.debugLn(tostring(key) .. " asked for the cab and every seat was taken; going back inside")
            notify(player, "IGUI_PhunInteriors_CabFull", true)
            placeInside(player, assignment, {
                vehicleId = record.vehicleId,
                vehicleHandle = handle,
                seat = -1,
                standSeat = -1,
                zombieSnapshot = 0
            })
        else
            -- Their lease went while they were in transit, which is a strange
            -- thing to have happened but not a reason to teleport them into a
            -- room somebody else now holds.
            Core.logLn("cannot put " .. tostring(key) ..
                " back after a full cab; the lease is no longer theirs")
            notify(player, "IGUI_PhunInteriors_CabFull", true)
        end
        return false
    end

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
    -- The vehicle is loaded again, so whatever the room banked on the way out
    -- can be taken off the battery now.
    Power.syncVehicle(record.vehicleId, vehicle)
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

--- Get a player out of a room that is no longer anybody's.
--
-- The case Transit.recover cannot answer. Recover walks the leases looking for
-- one whose box the player is standing in; when the lease has GONE -- reclaimed
-- while they were logged off, released by an admin, or lost with the mod's
-- store -- there is nothing for it to find, so the player is left standing in
-- a room the mod does not believe anybody is in. No occupancy means no leash,
-- no exit option and no containment: they are stuck, and walking out of the
-- door only puts them in the shell.
--
-- Two guards, and both matter. They must be standing in a REGISTERED slot,
-- which is what makes this about our rooms rather than about the map at large;
-- and they must have a stored entrance, which is what makes it about somebody
-- WE put there. An admin who walked into a room to look at it has no entrance
-- stored, so nothing happens to them.
--
-- Deliberately does not try to re-lease the room. Somebody else may hold it
-- now, and the honest outcome of a lease that is gone is that it is gone.
function Transit.rescueStranded(player)
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local roomId, index = Core.slotAt(x, y, z)
    if not roomId then
        return false
    end

    local at = Transit.fallbackReturn(player)
    if not at then
        return false
    end

    Core.logLn(string.format("%s logged in inside %s#%s with no lease on it; putting them back outside",
        tostring(Core.playerKey(player)), tostring(roomId), tostring(index)))

    -- Clears the stored entrance, which is the point of routing it through
    -- here rather than writing the modData directly: they are out, so the
    -- invariant that an entrance exists only while an occupancy does still
    -- holds. There is no occupancy to tear down, and setOccupancy counts the
    -- transition rather than the value, so this cannot unbalance the count.
    Transit.setOccupancy(player, nil)

    notify(player, "IGUI_PhunInteriors_RoomLost", true)
    Core.respond(player, Core.commands.teleport, {
        x = at.x,
        y = at.y,
        z = at.z,
        inside = false
    })
    return true
end

--- Rebuild occupancy for a player who logged in already inside a room, eg
--- after a server restart. Beats the reference approach of minting a fresh
--- random id and guessing by proximity.
function Transit.recover(player)
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local store = Slots.store()

    for vehicleId, assignment in pairs(store.assignments) do
        local room = Core.rooms[assignment.room]
        if room then
            -- The footprint, deliberately not the floor the leash contains on.
            -- A player who logged out a step past the south wall is still
            -- ours: recovered, the leash sees them over that edge and sends
            -- them out of it. Tested against the floor they would be found by
            -- nothing and left standing in the shell.
            local bounds = Core.slotBounds(room, assignment.index)
            if Core.inBounds(bounds, x, y, z) then
                Transit.setOccupancy(player, {
                    vehicleId = vehicleId,
                    room = assignment.room,
                    index = assignment.index,
                    seat = -1,
                    enteredAt = Core.now(),
                    zombieSnapshot = 0,
                    returnTo = assignment.lastKnownVehiclePos
                })
                Core.logLn("recovered " .. tostring(Core.playerKey(player)) ..
                    " inside " .. assignment.room .. "#" .. assignment.index)
                return true
            end
        end
    end

    return false
end

return Transit
