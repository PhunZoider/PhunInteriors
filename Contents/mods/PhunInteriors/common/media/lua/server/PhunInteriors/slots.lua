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
    Core.data.adopted = Core.data.adopted or false
    return Core.data
end
Slots.store = store

local function occupiedFor(roomSetId)
    local d = store()
    d.occupied[roomSetId] = d.occupied[roomSetId] or {}
    return d.occupied[roomSetId]
end

local function isQuarantined(roomSetId, index)
    for _, q in ipairs(store().quarantine) do
        if q.roomSet == roomSetId and q.index == index then
            return true
        end
    end
    return false
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

    -- slot 0 is the golden slot the manifest is scanned from, never leased
    for index = Core.consts.goldenSlot + 1, set.count do
        if not occupied[tostring(index)] and not isQuarantined(roomSetId, index) then
            local assignment = {
                roomSet = roomSetId,
                index = index,
                lastSeen = Core.now()
            }
            occupied[tostring(index)] = vehicleId
            d.assignments[vehicleId] = assignment
            Core.debugLn("leased " .. roomSetId .. "#" .. index .. " to " .. tostring(vehicleId))
            return assignment
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

    table.insert(d.quarantine, {
        roomSet = assignment.roomSet,
        index = assignment.index
    })

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

    for vehicleId, assignment in pairs(d.assignments) do
        -- never expire a room somebody is standing in
        local inUse = false
        for _, occupancy in pairs(Core.occupants) do
            if occupancy.vehicleId == vehicleId then
                inUse = true
                break
            end
        end

        if not inUse then
            local age = now - (assignment.lastSeen or now)
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

    if #expired > 0 then
        Core.logLn("lease sweep expired " .. #expired .. " room(s)")
    end
    return #expired
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
    local out = {sets = {}, quarantine = #d.quarantine}
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
    return out
end

return Slots
