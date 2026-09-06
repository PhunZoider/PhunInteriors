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
-- Every assignment carries a lastSeen stamp in world hours. A slot is never
-- returned straight to the pool: it goes to quarantine and is scrubbed on the
-- way back out, so a room is never reissued dirty.
-- ---------------------------------------------------------------------------

local function store()
    Core.data = Core.data or ModData.getOrCreate(Core.consts.modDataKey)
    Core.data.assignments = Core.data.assignments or {}   -- vehicleId -> {roomSet, index, lastSeen}
    Core.data.occupied = Core.data.occupied or {}         -- roomSet -> {index -> vehicleId}
    Core.data.quarantine = Core.data.quarantine or {}     -- list of {roomSet, index}
    Core.data.used = Core.data.used or {}                 -- roomSet -> {index -> true}
    Core.data.adopted = Core.data.adopted or false
    return Core.data
end
Slots.store = store

local function occupiedFor(roomSetId)
    local d = store()
    d.occupied[roomSetId] = d.occupied[roomSetId] or {}
    return d.occupied[roomSetId]
end

--- Drop a slot from the quarantine queue, if it is in it.
local function dequarantine(roomSetId, index)
    local queue = store().quarantine
    for i = #queue, 1, -1 do
        if queue[i].roomSet == roomSetId and queue[i].index == index then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

local function isQuarantined(roomSetId, index)
    for _, q in ipairs(store().quarantine) do
        if q.roomSet == roomSetId and q.index == index then
            return true
        end
    end
    return false
end

--- Has this slot ever been handed out? Marks it if not, and says which.
--
-- This is what makes a first lease capture trustworthy. A slot nobody has
-- ever been given has never been modified, so scanning it then is the only
-- moment we can be certain the blueprint describes a pristine room. Once the
-- flag is set it stays set, and a capture that fails is not retried on a
-- later lease -- by then the room has had a tenant and is no longer evidence
-- of anything.
function Slots.markUsed(roomSetId, index)
    local d = store()
    d.used[roomSetId] = d.used[roomSetId] or {}
    local key = tostring(index)
    if d.used[roomSetId][key] then
        return false
    end
    d.used[roomSetId][key] = true
    return true
end

--- The slot currently leased to this vehicle, or nil.
function Slots.find(vehicleId)
    if not vehicleId then
        return nil
    end
    return store().assignments[vehicleId]
end

--- Lease a slot to a vehicle, reusing its existing one if it has it.
-- Returns assignment, or nil plus a translation key.
function Slots.acquire(vehicleId, roomSetId)
    local set = Core.roomSets[roomSetId]
    if not set then
        return nil, "IGUI_PhunInteriors_NoRoomSet"
    end

    local d = store()
    local existing = d.assignments[vehicleId]
    if existing and existing.roomSet == roomSetId then
        existing.lastSeen = Core.now()
        return existing
    end

    local occupied = occupiedFor(roomSetId)

    local function lease(index, dirty)
        local assignment = {
            roomSet = roomSetId,
            index = index,
            lastSeen = Core.now()
        }
        occupied[tostring(index)] = vehicleId
        d.assignments[vehicleId] = assignment
        Core.debugLn("leased " .. roomSetId .. "#" .. index .. " to " .. tostring(vehicleId) ..
            (dirty and " (awaiting scrub)" or ""))
        return assignment
    end

    -- Every slot is leasable. Slot 0 used to be reserved as a pristine copy
    -- to scan blueprints from, which cost a room of map per set and only ever
    -- worked when somebody happened to be standing near it. Blueprints are
    -- authored now, and a slot that is leased captures its own.
    for index = 0, set.count do
        if not occupied[tostring(index)] and not isQuarantined(roomSetId, index) then
            return lease(index, false)
        end
    end

    -- Nothing clean left. Take a quarantined slot rather than refuse.
    --
    -- Quarantine used to be a one way door. A slot only leaves it by being
    -- scrubbed, a scrub needs the chunk loaded, and the chunk only loads when
    -- somebody is near the room -- which nobody is, because the room was
    -- released precisely because nobody was using it. The measured load radius
    -- is between 61 and 120 tiles against a 60 tile pitch, so only slots next
    -- to an occupied one ever drained. Every other released slot was lost for
    -- good and the pool shrank until the set reported itself full: exactly the
    -- reference mod's failure, reached from the opposite direction.
    --
    -- The invariant weakens from "never reissued dirty" to "never used dirty".
    -- The caller scrubs it, immediately if its chunk happens to be loaded and
    -- otherwise the moment the tenant arrives, which is the first point the
    -- chunk is guaranteed to exist.
    for index = 0, set.count do
        if not occupied[tostring(index)] and isQuarantined(roomSetId, index) then
            dequarantine(roomSetId, index)
            return lease(index, true), nil, true
        end
    end

    -- The reference mod returns silently here and the feature just stops
    -- working. Say something instead.
    Core.logLn("room set '" .. roomSetId .. "' is full (" .. set.count .. " slots)")
    return nil, "IGUI_PhunInteriors_NoFreeRoom"
end

--- Hand a slot back. It goes to quarantine, not to the pool.
function Slots.release(vehicleId, reason)
    local d = store()
    local assignment = d.assignments[vehicleId]
    if not assignment then
        return false
    end

    local occupied = occupiedFor(assignment.roomSet)
    occupied[tostring(assignment.index)] = nil
    d.assignments[vehicleId] = nil

    if not isQuarantined(assignment.roomSet, assignment.index) then
        table.insert(d.quarantine, {
            roomSet = assignment.roomSet,
            index = assignment.index
        })
    end

    Core.debugLn("released " .. assignment.roomSet .. "#" .. assignment.index ..
        " (" .. tostring(reason or "unspecified") .. ") -> quarantine")
    return true
end

--- Keep a lease alive. Called on every entry.
function Slots.touch(vehicleId)
    local assignment = store().assignments[vehicleId]
    if assignment then
        assignment.lastSeen = Core.now()
        -- renewing the lease re-arms the warning for next time
        assignment.warned = nil
    end
end

--- Adopt whatever already exists rather than judging it.
--
-- Borrowed from PhunServer2 Wiper: without this, installing the mod on a live
-- server with a 14 day lease would expire every room at once on day one.
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

--- Expire stale leases and leases whose vehicle no longer exists.
function Slots.sweepLeases()
    local leaseDays = Core.settings.LeaseDays or 0
    if leaseDays <= 0 then
        return 0
    end

    local d = store()
    local now = Core.now()
    local cutoff = leaseDays * 24
    local expired = {}

    -- Counted so the sweep can say why it did nothing. "expired 0 rooms" is
    -- indistinguishable between "no leases", "none old enough" and "the only
    -- candidate is occupied", and all three look like a broken sweep.
    local checked, skipped, oldest = 0, 0, 0

    for vehicleId, assignment in pairs(d.assignments) do
        checked = checked + 1

        -- never expire a room somebody is standing in
        local inUse = false
        for _, occupancy in pairs(Core.occupants) do
            if occupancy.vehicleId == vehicleId then
                inUse = true
                break
            end
        end

        if inUse then
            skipped = skipped + 1
        else
            local age = now - (assignment.lastSeen or now)
            if age > oldest then
                oldest = age
            end
            if age > cutoff then
                table.insert(expired, {id = vehicleId, reason = "lease expired"})
            else
                -- Tell the last person who used it, once, before it goes.
                local warnAfter = cutoff - ((Core.settings.LeaseWarningDays or 0) * 24)
                if age > warnAfter and not assignment.warned and assignment.lastUser then
                    local player = Core.tools.getPlayerByUsername(assignment.lastUser)
                    if player then
                        Core.respond(player, Core.commands.notify, {
                            text = "IGUI_PhunInteriors_LeaseWarning",
                            warning = true
                        })
                        assignment.warned = true
                    end
                end
            end
        end
    end

    for _, entry in ipairs(expired) do
        Slots.release(entry.id, entry.reason)
    end

    Slots.lastSweep = string.format(
        "%d lease(s) checked, %d occupied and skipped, oldest idle %.1f day(s), cutoff %d day(s)",
        checked, skipped, oldest / 24, leaseDays)

    if #expired > 0 then
        Core.logLn("lease sweep expired " .. #expired .. " room(s)")
    else
        Core.debugLn("lease sweep expired nothing: " .. Slots.lastSweep)
    end
    return #expired
end

--- Back-date a lease so it can be expired without waiting out the sandbox.
--
-- Purely a testing affordance. Lease expiry is otherwise only reachable by
-- letting fourteen in-game days pass, which meant the whole release ->
-- quarantine -> scrub chain had never been run once.
function Slots.age(vehicleId, days)
    local assignment = store().assignments[vehicleId]
    if not assignment then
        return nil
    end
    assignment.lastSeen = Core.now() - ((tonumber(days) or 0) * 24)
    assignment.warned = nil
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
    local out = {sets = {}, leases = {}, quarantine = #d.quarantine}

    -- Name them. A bare count tells you nothing about whether the queue is
    -- draining or quietly eating the pool.
    if #d.quarantine > 0 then
        local names = {}
        for _, entry in ipairs(d.quarantine) do
            table.insert(names, entry.roomSet .. "#" .. entry.index)
        end
        out.quarantined = " (" .. table.concat(names, ", ") .. ")"
    end
    for id, set in pairs(Core.roomSets) do
        local used = 0
        for _ in pairs(occupiedFor(id)) do
            used = used + 1
        end
        table.insert(out.sets, {
            id = id,
            used = used,
            total = set.count,
            source = set.source
        })
    end

    -- The leases themselves, not just how many. Every other admin action
    -- takes a vehicleId, and a summary that only counts them leaves no way to
    -- find one.
    local now = Core.now()
    for vehicleId, assignment in pairs(d.assignments) do
        local inUse = false
        for _, occupancy in pairs(Core.occupants) do
            if occupancy.vehicleId == vehicleId then
                inUse = true
                break
            end
        end
        table.insert(out.leases, {
            vehicleId = vehicleId,
            roomSet = assignment.roomSet,
            index = assignment.index,
            idleDays = (now - (assignment.lastSeen or now)) / 24,
            lastUser = assignment.lastUser,
            warned = assignment.warned and true or false,
            occupied = inUse
        })
    end
    table.sort(out.leases, function(a, b) return a.idleDays > b.idleDays end)

    return out
end

return Slots
