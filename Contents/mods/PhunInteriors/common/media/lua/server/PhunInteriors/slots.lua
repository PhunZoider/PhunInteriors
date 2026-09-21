if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = {}
Core.modules.slots = Slots

-- ---------------------------------------------------------------------------
-- Slot allocation, leases and the quarantine queue.
--
-- Every assignment carries a lastSeen stamp in world hours. Nothing expires on
-- a clock: a lease is only taken away when a vehicle needs a room, every room
-- it could have is full, and this one has gone unused for RoomProtectedDays.
-- A slot is never returned straight to the pool either: it goes to quarantine
-- and is scrubbed when it is handed out again, so a room is never used dirty.
-- ---------------------------------------------------------------------------

local function store()
    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    Core.data.assignments = Core.data.assignments or {} -- vehicleId -> {room, index, lastSeen}
    Core.data.occupied = Core.data.occupied or {} -- room -> {index -> vehicleId}
    Core.data.quarantine = Core.data.quarantine or {} -- list of {room, index}
    Core.data.used = Core.data.used or {} -- room -> {index -> true}
    Core.data.closed = Core.data.closed or {} -- room -> {at = world hours}
    Core.data.adopted = Core.data.adopted or false
    return Core.data
end
Slots.store = store

local function occupiedFor(roomId)
    local d = store()
    d.occupied[roomId] = d.occupied[roomId] or {}
    return d.occupied[roomId]
end

--- Drop a slot from the quarantine queue, if it is in it.
local function dequarantine(roomId, index)
    local queue = store().quarantine
    for i = #queue, 1, -1 do
        if queue[i].room == roomId and queue[i].index == index then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

local function isQuarantined(roomId, index)
    for _, q in ipairs(store().quarantine) do
        if q.room == roomId and q.index == index then
            return true
        end
    end
    return false
end

--- Is somebody standing in the room leased to this vehicle?
--
-- Includes a tenant who disconnected inside: Core.occupants keeps their record
-- until they come back, and their room must still be there when they do.
local function isOccupied(vehicleId)
    for _, occupancy in pairs(Core.occupants) do
        if occupancy.vehicleId == vehicleId then
            return true
        end
    end
    return false
end
Slots.isOccupied = isOccupied

--- Put a slot in the queue to be scrubbed, whether or not anybody holds it.
--
-- Release does this for a leased slot. This is for one nobody holds -- a room
-- being reset on request -- so it goes through the same queue, and the same
-- scrub on reissue, rather than being a second kind of dirty.
function Slots.markDirty(roomId, index)
    if isQuarantined(roomId, index) then
        return false
    end
    table.insert(store().quarantine, {
        room = roomId,
        index = index
    })
    return true
end

--- Take a slot out of the queue because it has just been scrubbed.
Slots.markClean = dequarantine

-- ---------------------------------------------------------------------------
-- Open and closed.
--
-- A closed room hands out nothing: no new lease, no reclaim into it, and no
-- way back in for somebody who already holds one. What it does NOT do is
-- touch anybody inside -- leaving is always allowed, and turning people out is
-- the caller's choice (Transit.setRoomOpen's `evict`).
--
-- Runtime state rather than a contract field, which is why it is here and
-- not in registerRoom or the override file. The contract says what a room IS;
-- whether it is open right now is something a schedule or an admin changes
-- while the server runs. It is kept in the save, so a room an admin closed is
-- still closed after a restart; a schedule simply re-asserts it.
-- ---------------------------------------------------------------------------

function Slots.isOpen(roomId)
    return store().closed[roomId] == nil
end

--- Returns true when the state changed.
function Slots.setOpen(roomId, open)
    local closed = store().closed
    local was = closed[roomId] == nil
    if open then
        closed[roomId] = nil
    else
        closed[roomId] = closed[roomId] or {
            at = Core.now()
        }
    end
    return was ~= (open and true or false)
end

--- How long a lease is safe from being taken, in world hours.
---
--- BOTH ENDS OF THE RANGE MEAN SOMETHING, and that is why there is no separate
--- "allow reclaiming" tick beside it. Zero lets any unused room be taken the
--- moment the pool is full; the top of the range -- 99999999 days, absurd on
--- purpose -- is how an admin says NEVER, and a vehicle is simply refused once
--- the last room is gone. A tick and a threshold would be two controls for one
--- decision, and a server with the tick off and a threshold of three would be
--- saying two different things about the same room.
---
--- No special case for the maximum: it is just a number so large that
--- `(now - lastSeen) >= it` cannot become true inside any save. Treating some
--- value as infinity would be a third meaning for one field.
local function protectedHours()
    local days = tonumber(Core.settings.RoomProtectedDays or Core.defaults.RoomProtectedDays) or 0
    return math.max(0, days) * 24
end

--- The safehouse claimed over this slot, or nil.
--
-- A room somebody has claimed is theirs in a way a lease is not: the game has
-- promised them nobody else touches it. So a claimed slot is never scrubbed,
-- never reclaimed and never handed to another vehicle. Whoever holds the lease
-- keeps it for as long as the claim stands, and a released one waits in
-- quarantine until the claim goes -- by the owner, an admin, or vanilla's own
-- inactivity removal.
--
-- getSafehouseOverlapping walks the global safehouse list rather than reading
-- a square, so this answers with the room's chunk unloaded, which is nearly
-- always. Its rectangle is half open -- from the bytecode it matches when
-- x1 < house.x + w and x2 > house.x -- so the inclusive slot bounds go in with
-- one added to the far edges. Without that a claim covering only the last row
-- or column, where the south and east walls stand, would be missed.
function Slots.safehouseOn(roomId, index)
    if not SafeHouse or not SafeHouse.getSafehouseOverlapping then
        return nil
    end
    local room = Core.rooms[roomId]
    local bounds = room and Core.slotBounds(room, index)
    if not bounds then
        return nil
    end
    return SafeHouse.getSafehouseOverlapping(bounds.x1, bounds.y1, bounds.x2 + 1, bounds.y2 + 1)
end

--- The claim standing over this slot that `player` is not welcome in, or nil.
---
--- Separate from Slots.safehouseOn, which asks whether there is a claim at
--- all. Every other guard in this file wants that one -- do not scrub, do not
--- reclaim, do not hand it to a stranger -- and this one asks the different
--- question of whether a particular person may walk in.
---
--- `playerAllowed` answers member OR owner OR the role capability
--- `CanGoInsideSafehouses`, read straight off the bytecode. That last clause
--- is why there is NO admin exemption written here: vanilla already has one,
--- it is the same one that governs every other safehouse in the world, and an
--- admin who has it is allowed for the same reason they are allowed anywhere
--- else. Writing our own would repeat the mistake the tent pickup guard made
--- -- a guard that exempts admins cannot be tested by an admin, and everybody
--- who tests this mod is one.
---
--- Reads no square, so it answers with the room's chunk unloaded, which it
--- always is at the moment somebody asks to go in.
function Slots.trespassOn(roomId, index, player)
    if not player then
        return nil
    end
    local claim = Slots.safehouseOn(roomId, index)
    if not claim or not claim.playerAllowed then
        return nil
    end
    if claim:playerAllowed(player) then
        return nil
    end
    return claim
end

--- May this slot be given to a vehicle that does not already hold it?
--
-- Cheapest test first: the claim walks a Java list, and allocation asks this
-- of every slot in a room until one answers yes.
local function isSpare(roomId, index, occupied)
    return not occupied[tostring(index)] and not Slots.safehouseOn(roomId, index)
end

--- Has this slot ever been handed out? Marks it if not, and says which.
--
-- This is what makes a first lease capture trustworthy. A slot nobody has
-- ever been given has never been modified, so scanning it then is the only
-- moment we can be certain the blueprint describes a pristine room. Once the
-- flag is set it stays set, and a capture that fails is not retried on a
-- later lease -- by then the room has had a tenant and is no longer evidence
-- of anything.
function Slots.markUsed(roomId, index)
    local d = store()
    d.used[roomId] = d.used[roomId] or {}
    local key = tostring(index)
    if d.used[roomId][key] then
        return false
    end
    d.used[roomId][key] = true
    return true
end

--- Write the lease down. Shared by the two ways of arriving at one.
--
-- Hoisted out of Slots.acquire when the admin tool needed to lease a room by
-- name: the decision of WHICH slot differs completely between "what is this
-- vehicle entitled to" and "the one the admin pointed at", and the bookkeeping
-- that follows it does not differ at all.
local function leaseTo(vehicleId, roomId, index, dirty)
    local d = store()
    local assignment = {
        room = roomId,
        index = index,
        lastSeen = Core.now(),
        -- A new tenant walks into a lit room rather than groping for the
        -- switch. On the LEASE rather than the occupancy, so it happens once
        -- per tenancy: whoever turns the lights off afterwards keeps them off.
        -- The leash clears it, being the first moment the room is loaded.
        lightsPending = true
    }
    occupiedFor(roomId)[tostring(index)] = vehicleId
    d.assignments[vehicleId] = assignment
    Core.debugLn("leased " .. roomId .. "#" .. index .. " to " .. tostring(vehicleId) ..
                     (dirty and " (awaiting scrub)" or ""))
    return assignment
end

--- The slot currently leased to this vehicle, or nil.
function Slots.find(vehicleId)
    if not vehicleId then
        return nil
    end
    return store().assignments[vehicleId]
end

--- May this lease be taken to make room for somebody else?
--
-- Unused for at least RoomProtectedDays, nobody inside, and nobody has claimed
-- it as a safehouse. Whether anybody actually needs it is the caller's
-- question; this only says it is allowed.
function Slots.isReclaimable(vehicleId, assignment)
    local now = Core.now()
    return (now - (assignment.lastSeen or now)) >= protectedHours()
        and not isOccupied(vehicleId)
        and not Slots.safehouseOn(assignment.room, assignment.index)
end

--- Why this lease's holder must not be packed away, or nil when it may be.
--
-- Only a holder that can be carried off cares -- a tent -- but the question is
-- about the lease rather than about tents, so it is answered here beside the
-- lease and not in the world object code.
--
-- TWO TESTS, AND THEY ARE NOT THE SAME TEST WEARING TWO HATS.
--
--   * Occupied is measured, now, and is unconditional. Picking up a tent with
--     somebody inside strands them on bare ground whether or not the room
--     holds a single item, so this one is not about belongings at all. It
--     includes a tenant who disconnected in there, because isOccupied does.
--
--   * Contents is a BANKED fact, not a measured one, and it has to be. At the
--     moment somebody reaches for the tent the tent is loaded and the room is
--     not -- the same split that killed scrubbing a slot on release, where the
--     chunk only loads when somebody is near a room that by definition nobody
--     is near. So it is measured on the way out, where the tenant is standing
--     in the room and it is loaded by construction.
--
-- The banked number is exact rather than stale, and that is a property of the
-- design rather than luck: nobody can put anything into a room without being
-- inside it, and being inside it means leaving it again, which re-measures. So
-- a room's contents cannot change while nobody is there to change them.
function Slots.lockReason(leaseKey)
    if not leaseKey then
        return nil
    end
    if isOccupied(leaseKey) then
        return "occupied"
    end
    local assignment = store().assignments[leaseKey]
    if assignment and (tonumber(assignment.contents) or 0) > 0 then
        return "contents"
    end
    return nil
end

--- Does lease a belong ahead of lease b in the queue to be reclaimed?
--
-- Longest unused first. Everything after that only breaks ties, and ties are
-- ordinary rather than rare -- adoptBaseline stamps every lease with the same
-- hour -- while pairs() does not visit them in the same order twice. Without
-- the tail the same save could reclaim a different room on a second run.
local function reclaimsBefore(aId, a, bId, b, rooms)
    local now = Core.now()
    local seenA, seenB = a.lastSeen or now, b.lastSeen or now
    if seenA ~= seenB then
        return seenA < seenB
    end
    local rankA, rankB = rooms and rooms[a.room] or 0, rooms and rooms[b.room] or 0
    if rankA ~= rankB then
        return rankA < rankB
    end
    if a.room ~= b.room then
        return a.room < b.room
    end
    if a.index ~= b.index then
        return a.index < b.index
    end
    return tostring(aId) < tostring(bId)
end

--- The lease that has gone unused the longest, among those that may be taken.
--
-- @param rooms a set of room id -> rank to choose among, or nil for any room.
--        Rank is the room's place in the vehicle's candidate list, and only
--        ever breaks a tie.
-- Returns vehicleId, assignment -- or nil when nothing qualifies.
function Slots.oldestReclaimable(rooms)
    local bestId, best = nil, nil
    for vehicleId, assignment in pairs(store().assignments) do
        local room = Core.rooms[assignment.room]
        -- A lease pointing at a slot that no longer exists is not a room to
        -- hand anybody. Slots.acquire lets those go when their own vehicle
        -- next asks.
        local inScope = room and (not rooms or rooms[assignment.room]) and Core.slotOrigin(room, assignment.index)
        if inScope and Slots.isReclaimable(vehicleId, assignment)
            and (not best or reclaimsBefore(vehicleId, assignment, bestId, best, rooms)) then
            bestId, best = vehicleId, assignment
        end
    end
    return bestId, best
end

--- Lease a slot to a vehicle, reusing its existing one if it has it.
-- @param vehicle the holder asking. Needed in full, not just an id, because
--        which rooms it is entitled to is resolved from its script or its
--        moveable item type.
-- Returns assignment, or nil plus a translation key, plus dirty.
function Slots.acquire(vehicleId, vehicle)
    -- Holder agnostic, and now completely so. Since world objects became
    -- holders, `vehicle` is whatever holds this lease, and the last thing
    -- below that read it as a vehicle -- Core.roomAllows, testing each room's
    -- `requires` -- is gone. It is used to resolve the candidates and for
    -- nothing else.
    local candidates = Core.roomsForHolder(vehicle)
    if #candidates == 0 then
        -- Two very different causes wear the same message, so say which. A
        -- vehicle bound to nothing is a mod that never finished the job; a
        -- vehicle bound to a room nobody registered is a missing map pack, and
        -- the player can act on that one.
        -- Only a vehicle can be asked this; unresolvedFor walks script names.
        -- An object refused a room falls through to the generic message.
        local missing = (vehicle and vehicle.getScript) and Core.unresolvedFor(vehicle) or nil
        if missing then
            Core.logLn("this vehicle is bound to " .. table.concat(missing, ", ") ..
                           ", which nothing registered -- is that mod installed?")
        else
            Core.logLn("this vehicle has no rooms bound to it")
        end
        return nil, "IGUI_PhunInteriors_NoRoomSet"
    end

    local d = store()
    local existing = d.assignments[vehicleId]
    if existing then
        if Core.rooms[existing.room] and Core.slotOrigin(Core.rooms[existing.room], existing.index) then
            -- Their room, and their belongings, are still where they left
            -- them. Whether that room is still bound to this vehicle is a
            -- question for the next lease, not this one: leasing again would
            -- hand them a different room and orphan the old one, occupied and
            -- unreachable, for the life of the save.
            --
            -- Unless the room is closed. The lease is theirs and survives;
            -- going in is what waits. Refused before the touch below, because
            -- a refused entry must not renew what the reclaim measures.
            if not Slots.isOpen(existing.room) then
                return nil, "IGUI_PhunInteriors_RoomClosed"
            end
            existing.lastSeen = Core.now()
            return existing
        end
        -- The room genuinely no longer exists -- it was unregistered, or
        -- re-registered with fewer slots. Let the lease go rather than leave
        -- the vehicle pointing at nothing.
        Core.logLn("lease for " .. tostring(vehicleId) .. " pointed at missing room " .. tostring(existing.room) ..
                       "#" .. tostring(existing.index) .. "; releasing")
        Slots.release(vehicleId, "room no longer registered")
    end

    local function lease(roomId, index, dirty)
        return leaseTo(vehicleId, roomId, index, dirty)
    end

    -- Most specialised room first -- see the ordering in registry.lua's
    -- rebuild.
    --
    -- Note this is per room, not clean-everywhere-then-quarantined-everywhere.
    -- Draining all the clean slots across every room before touching a
    -- quarantined one would reach into the general purpose rooms while the
    -- specialised ones still had slots free, which is the same starvation the
    -- ordering exists to prevent, arrived at from the other side.
    -- The rooms that would have this vehicle, with their place in the order,
    -- for the reclaim below. Every candidate ends up in here now that a room
    -- cannot refuse a holder; it is kept because the reclaim needs the RANK,
    -- not because the set is ever smaller than `candidates`.
    local allowedRooms = {}
    local anyOpen = false
    for rank, roomId in ipairs(candidates) do
        local room = Core.rooms[roomId]

        -- A closed room is not a candidate at all, and is left out of
        -- allowedRooms too, so the reclaim below cannot reach into one either.
        if Slots.isOpen(roomId) then
            anyOpen = true

            -- Every candidate is allowed. A room used to be able to state demands
            -- on the holder here -- Core.roomAllows, `requires` -- tested per
            -- candidate so that a vehicle failing one room could still be given
            -- the next. Both are gone: nothing on the shipped map ever declared
            -- one, and asking a vehicle question during allocation, which is
            -- holder agnostic, is what once made every room unreachable for a
            -- tent. Whether a holder may have a room is the binding's answer, and
            -- Core.roomsForHolder above has already applied it.
            allowedRooms[roomId] = rank
            local occupied = occupiedFor(roomId)

            -- Every slot is leasable. Slot 0 used to be reserved as a pristine
            -- copy to scan blueprints from, which cost a room of map per set
            -- and only ever worked when somebody happened to be standing near
            -- it. Blueprints are authored now, and the first slot leased
            -- captures the room's.
            --
            -- A slot with a safehouse claimed over it is skipped even when
            -- nobody holds its lease: it is somebody's, and handing it to a
            -- stranger would give them the owner's room and the owner's things.
            for _, index in ipairs(room.indices) do
                if isSpare(roomId, index, occupied) and not isQuarantined(roomId, index) then
                    return lease(roomId, index, false)
                end
            end

            -- Quarantine used to be a one way door. A slot only left it by
            -- being scrubbed, a scrub needs the chunk loaded, and the chunk
            -- only loads when somebody is near the room -- which nobody is,
            -- because the room was released precisely because nobody was using
            -- it. The measured load radius is between 61 and 120 tiles against
            -- a 60 tile pitch, so only slots next to an occupied one ever
            -- drained. Every other released slot was lost for good and the
            -- pool shrank until the set reported itself full: exactly the
            -- reference mod's failure, reached from the opposite direction.
            --
            -- The invariant weakens from "never reissued dirty" to "never used
            -- dirty". The caller scrubs it, immediately if its chunk happens
            -- to be loaded and otherwise the moment the tenant arrives, which
            -- is the first point the chunk is guaranteed to exist.
            for _, index in ipairs(room.indices) do
                if isSpare(roomId, index, occupied) and isQuarantined(roomId, index) then
                    dequarantine(roomId, index)
                    return lease(roomId, index, true), nil, true
                end
            end
        end
    end

    -- Every room this holder could have is shut, which is a different answer
    -- from "they are all full" and the player can act on it: come back later.
    if not anyOpen then
        Core.debugLn("every room for this holder is closed: " .. table.concat(candidates, ", "))
        return nil, "IGUI_PhunInteriors_RoomClosed"
    end

    -- Every room this vehicle could have is full. Take the one nobody has used
    -- for the longest, if nobody has used it for long enough.
    --
    -- This is the only way a lease ever ends by itself. It used to be a daily
    -- sweep that released anything idle past LeaseDays, which threw a tenant's
    -- belongings away on schedule whether or not anybody wanted the slot --
    -- with a thousand rooms standing empty. A room is only worth taking from
    -- somebody when somebody else needs it, so that is the only time it is.
    --
    -- After every free and quarantined slot in every room, not per room like
    -- those two. Those decide which spare capacity to spend; this decides
    -- whose room to take, and spending a general purpose slot always beats
    -- emptying somebody's van.
    --
    -- And the longest unused across all of them, not the most specialised
    -- room first. With everything full there is no spare capacity left to
    -- save for anybody, so what is left is fairness, and the fair answer is
    -- the room nobody has wanted for the longest.
    local holder, taken = Slots.oldestReclaimable(allowedRooms)
    if holder then
        local roomId, index = taken.room, taken.index
        Core.logLn(string.format("reclaimed %s#%s from %s, unused for %.1f day(s)", roomId, tostring(index),
            tostring(holder), (Core.now() - (taken.lastSeen or Core.now())) / 24))
        Slots.release(holder, "reclaimed")
        dequarantine(roomId, index)
        return lease(roomId, index, true), nil, true
    end

    -- There used to be a branch here for "every room this vehicle is entitled
    -- to refused it outright", which was a different failure from "they are
    -- all full" and carried its own message. It went with `requires`: a room
    -- can no longer refuse a holder, so the only way to reach this point is a
    -- full pool.
    --
    -- The reference mod returns silently here and the feature just stops
    -- working. Say something instead, and name every set that was tried --
    -- "full" is a different problem depending on whether it was one set or
    -- five, and the specificity ordering means the set a player would guess at
    -- is not necessarily the one that filled.
    Core.logLn(string.format(
        "no free room: every slot of %s is leased or claimed, and none has gone unused for %s day(s)",
        table.concat(candidates, ", "), tostring(protectedHours() / 24)))
    return nil, "IGUI_PhunInteriors_NoFreeRoom"
end

--- Lease a named room, and optionally a named slot, ignoring the bindings.
--
-- Deliberately not a flag on Slots.acquire. That function answers "which room
-- is this vehicle entitled to", and every line of it -- the candidate list,
-- the specificity order, the reclaim -- exists to answer it well.
-- The admin tool is not asking that question at all: it wants room number
-- nine because room number nine is the one being designed, and there may be
-- no vehicle in the world at the time.
--
-- index nil takes the next free slot, passing over any somebody has claimed as
-- a safehouse. A named index is honoured even when claimed, because an admin
-- pointed at it -- the scrub will still refuse to touch it. A quarantined index
-- is allowed, and comes back flagged dirty, which is what makes release ->
-- re-enter -> watch it scrub a thing an admin can actually do. Someone else's
-- live lease is never taken.
--
-- Returns assignment, or nil plus a plain-English reason, plus dirty.
function Slots.acquireIn(vehicleId, roomId, index)
    local room = Core.rooms[roomId]
    if not room then
        return nil, "there is no room called " .. tostring(roomId)
    end

    local d = store()
    local occupied = occupiedFor(roomId)
    local existing = d.assignments[vehicleId]

    -- Already holding the slot being asked for. Renew rather than churn it
    -- through quarantine, so an admin stepping in and out of one room to look
    -- at a change does not eat a fresh slot every time.
    if existing and existing.room == roomId and (index == nil or existing.index == index)
        and Core.slotOrigin(room, existing.index) then
        existing.lastSeen = Core.now()
        return existing, nil, false
    end

    if index ~= nil then
        if not Core.slotOrigin(room, index) then
            return nil, string.format("%s has no slot %s", roomId, tostring(index))
        end
        local holder = occupied[tostring(index)]
        if holder and holder ~= vehicleId then
            return nil, string.format("%s#%s is leased to %s", roomId, tostring(index), tostring(holder))
        end
    else
        index = nil
        for _, candidate in ipairs(room.indices) do
            if isSpare(roomId, candidate, occupied) and not isQuarantined(roomId, candidate) then
                index = candidate
                break
            end
        end
        if index == nil then
            for _, candidate in ipairs(room.indices) do
                if isSpare(roomId, candidate, occupied) then
                    index = candidate
                    break
                end
            end
        end
        if index == nil then
            return nil, "every slot in " .. roomId .. " is leased or claimed as a safehouse"
        end
    end

    -- Whatever they were holding before goes back, which is the same rule the
    -- vehicle path follows: one lease per holder. It lands in quarantine like
    -- any other release, so the room an admin has just walked through is
    -- cleaned up rather than left as they left it.
    if existing then
        Slots.release(vehicleId, "leasing " .. roomId .. " instead")
        -- release() may have put the slot we are about to take into
        -- quarantine, in which case the dequarantine below picks it up again.
    end

    local dirty = dequarantine(roomId, index)
    return leaseTo(vehicleId, roomId, index, dirty), nil, dirty
end

--- Hand a slot back. It goes to quarantine, not to the pool.
function Slots.release(vehicleId, reason)
    local d = store()
    local assignment = d.assignments[vehicleId]
    if not assignment then
        return false
    end

    -- Hand back whatever mass we added, if the vehicle happens to be loaded.
    --
    -- This used to call Weight.queue, a 1Hz poll that waited up to thirty
    -- seconds for the vehicle to reappear. That function was deleted when
    -- weight became arrival-driven and this call was left behind, so every
    -- release with a stored position threw "Object tried to call nil" -- dead
    -- since 0ab366a and only reachable on the admin path, which had never run.
    --
    -- One sweep and no poll, because there is nothing to wait for: a lease is
    -- usually released precisely because nobody is near the vehicle, and a
    -- reclaimed one has gone unused for days. Missing it is survivable.
    -- Weight.apply composes over the stored delta --
    -- setMass(getMass() - applied + want) -- so the next lease this vehicle
    -- takes charges it the difference rather than the total, and the stale
    -- delta is corrected at the first arrival rather than compounding.
    --
    -- Skipped for every holder that is not a vehicle, because there is no
    -- vehicle to find: an admin lease is keyed admin:<username> and a world
    -- object lease object:<uuid>, neither of which could ever match a UUID, so
    -- the sweep would read 49 squares and report a missing vehicle on every
    -- release. weight.lua is required lazily because it requires this file.
    local at = assignment.lastKnownVehiclePos
    local kind = Core.holderKind(vehicleId)
    if at and kind == "vehicle" then
        local vehicle = Core.vehicleNear(at.x, at.y, at.z, vehicleId)
        if vehicle then
            require("PhunInteriors/weight").apply(vehicle, 0)
        else
            Core.debugLn("released " .. tostring(vehicleId) ..
                             " while its vehicle was unloaded; the mass delta stays on it until its next lease")
        end
    end

    -- A world object that can be carried off was refusing to be, on behalf of
    -- a lease that no longer exists. Cleared here when the object is loaded,
    -- which it is whenever a release happens with somebody standing there --
    -- an admin release, or a re-lease into a different room.
    --
    -- It very often is NOT loaded: a reclaim takes rooms precisely because
    -- nobody has been near them for days. That case is left alone rather than
    -- chased, because it heals itself -- entering the object takes a fresh
    -- room and leaving it re-asserts the lock against that room, which for an
    -- empty one means clearing it. The cost of not healing is a tent that has
    -- to be walked into once before it can be packed away, and the cost of
    -- chasing it would be a poll for a chunk nobody is near.
    if at and kind == "object" then
        local object = Core.boundObjectAt(at.x, at.y, at.z or 0)
        if object and Core.objectKey(Core.objectId(object, false)) == vehicleId then
            Core.setObjectLock(object, nil)
            Core.debugLn("released " .. tostring(vehicleId) .. "; its holder may be packed away again")
        end
    end

    local occupied = occupiedFor(assignment.room)
    occupied[tostring(assignment.index)] = nil
    d.assignments[vehicleId] = nil

    if not isQuarantined(assignment.room, assignment.index) then
        table.insert(d.quarantine, {
            room = assignment.room,
            index = assignment.index
        })
    end

    Core.debugLn("released " .. assignment.room .. "#" .. assignment.index .. " (" ..
                     tostring(reason or "unspecified") .. ") -> quarantine")
    return true
end

--- Keep a lease alive. Called on every entry and exit.
function Slots.touch(vehicleId)
    local assignment = store().assignments[vehicleId]
    if assignment then
        assignment.lastSeen = Core.now()
    end
end

--- Adopt whatever already exists rather than judging it.
--
-- Borrowed from PhunServer2 Wiper: without this, upgrading a live server
-- whose leases carry no usable lastSeen would make every one of them
-- reclaimable the first time the pool filled.
function Slots.adoptBaseline()
    local d = store()
    if d.adopted then
        return
    end
    local now = Core.now()
    local count = 0
    for _, assignment in pairs(d.assignments) do
        assignment.lastSeen = now
        count = count + 1
    end
    d.adopted = true
    if count > 0 then
        Core.logLn("adopted " .. count .. " existing assignment(s) at the current world age")
    end
end

--- Back-date a lease so it can be reclaimed without waiting out the sandbox.
--
-- Purely a testing affordance. Reclaiming is otherwise only reachable by
-- waiting RoomProtectedDays and then filling every room a vehicle could have,
-- which on the shipped map is 1200 of them.
function Slots.age(vehicleId, days)
    local assignment = store().assignments[vehicleId]
    if not assignment then
        return nil
    end
    assignment.lastSeen = Core.now() - ((tonumber(days) or 0) * 24)
    return assignment
end

--- Pop one quarantined slot for scrubbing. Returns nil when the queue is empty.
function Slots.nextQuarantined()
    local d = store()
    if #d.quarantine == 0 then
        return nil
    end
    return table.remove(d.quarantine, 1)
end

function Slots.summary()
    local d = store()
    local out = {
        rooms = {},
        leases = {},
        quarantine = #d.quarantine
    }

    -- Name them. A bare count tells you nothing about whether the queue is
    -- draining or quietly eating the pool.
    if #d.quarantine > 0 then
        local names = {}
        for _, entry in ipairs(d.quarantine) do
            table.insert(names, entry.room .. "#" .. entry.index)
        end
        out.quarantined = " (" .. table.concat(names, ", ") .. ")"
    end
    for id, room in pairs(Core.rooms) do
        local used = 0
        for _ in pairs(occupiedFor(id)) do
            used = used + 1
        end
        table.insert(out.rooms, {
            id = id,
            used = used,
            total = #room.indices,
            source = room.source
        })
    end

    -- The leases themselves, not just how many. Every other admin action
    -- takes a vehicleId, and a summary that only counts them leaves no way to
    -- find one.
    local now = Core.now()
    for vehicleId, assignment in pairs(d.assignments) do
        local claim = Slots.safehouseOn(assignment.room, assignment.index)
        table.insert(out.leases, {
            vehicleId = vehicleId,
            room = assignment.room,
            index = assignment.index,
            idleDays = (now - (assignment.lastSeen or now)) / 24,
            lastUser = assignment.lastUser,
            reclaimable = Slots.isReclaimable(vehicleId, assignment),
            -- Named, because a claim is the one thing that makes a room
            -- permanent and "why will this never be reclaimed" deserves an
            -- answer with a person in it.
            claimedBy = claim and tostring(claim:getOwner()) or nil,
            occupied = isOccupied(vehicleId),
            -- Where the exit will send whoever is inside. Reported because it
            -- is the one piece of state the whole exit path stands on and
            -- nothing else makes it visible.
            at = assignment.lastKnownVehiclePos,
            loaded = assignment.lastKnownHandle and getVehicleById(assignment.lastKnownHandle) ~= nil or false
        })
    end
    table.sort(out.leases, function(a, b)
        return a.idleDays > b.idleDays
    end)

    return out
end

return Slots
