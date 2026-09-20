if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Transit = require "PhunInteriors/transit"

-- ---------------------------------------------------------------------------
-- Releasing the room of a vehicle that has left the world for good.
--
-- A lease is keyed on a UUID in the vehicle's modData, so once the vehicle is
-- gone nothing can ever carry that key through the door again. Left alone the
-- room still counts as leased, which matters once the pool is full: a reclaim
-- takes the room unused the longest, and that may well be a living player's
-- rather than this one, abandoned more recently. Released here, the slot is
-- simply free, and free slots are always spent before anybody's room is taken.
--
-- There is no event to hang this on. It used to be a handler on
-- Events.OnVehicleDestroyed, which B42's LuaEventManager does not declare. The
-- handler tested for the event before adding itself, so it skipped itself
-- without a word and never ran once.
--
-- Nor can "has it been removed" be asked after the fact. permanentlyRemove()
-- calls removeFromWorld(), and so does an ordinary chunk unload, so
-- isRemovedFromWorld() is true of every parked vehicle nobody is standing
-- near. The only evidence is the change: false going into a removal, true
-- coming out of it. So this hooks the calls that remove a vehicle rather than
-- trying to recognise one that has been removed.
--
-- Vanilla has two, found by grepping media/lua for permanentlyRemove:
--
--   ISRemoveBurntVehicle:complete()   The blowtorch on a burnt wreck. Runs
--                                     server side, so it is wrapped here and
--                                     the before and after are one call apart.
--
--   The admin "remove vehicle" cheat  ISVehicleMechanics.onCheatRemoveAux,
--                                     client code that sends
--                                     VehicleCommands.remove -- a local table
--                                     nothing outside that file can reach. So
--                                     the client says it is about to
--                                     (client_tracker.lua) and the server
--                                     watches for the change.
--
-- Stripping a van for parts is not removal: the chassis keeps its modData, so
-- it keeps its room, which is right. Another mod calling permanentlyRemove()
-- is not seen at all; its room goes unrenewed and is reclaimed like any other.
-- ---------------------------------------------------------------------------

local Removal = {}

-- How long a watch waits for the removal it was warned about. The warning and
-- vanilla's own command leave the same client one after the other, so this is
-- only ever waiting on a frame or two. Generous because giving up early costs
-- somebody a room, and waiting costs nothing.
local WATCH_MS = 5000

local watched = nil
local installed = false

local function tenantOf(vehicleId)
    for key, occupancy in pairs(Core.occupants) do
        if occupancy.vehicleId == vehicleId then
            return key
        end
    end
    return nil
end

--- Put out anybody inside the room, then release it.
--
-- Refuses if anybody cannot be put out, for the reason admin release does:
-- the leash reads the lease, and pulling it out from under a tenant leaves the
-- leash ejecting them to nowhere. A refused room is not lost, only late --
-- once they have left it goes unrenewed, and a full pool reclaims it.
function Removal.vacate(vehicleId, why)
    local key = tenantOf(vehicleId)
    while key do
        local player = Core.tools.getPlayerByUsername(key)
        local left, reason = false, "offline"
        if player then
            left, reason = Transit.leave(player, "breach")
        end
        -- A leave that went through cleared its occupancy, so asking again
        -- moves on to the next tenant. Getting the same one back means it
        -- did not, and asking a third time would never end.
        local after = left and tenantOf(vehicleId)
        if not left or after == key then
            Core.logLn(string.format("%s (%s) but %s is still inside (%s); keeping the room",
                tostring(vehicleId), tostring(why), tostring(key), tostring(reason)))
            return false
        end
        key = after
    end

    if Slots.release(vehicleId, why) then
        Core.logLn("released the room leased to " .. tostring(vehicleId) .. ": " .. tostring(why))
        return true
    end
    return false
end

local function hookScrap()
    if not ISRemoveBurntVehicle or not ISRemoveBurntVehicle.complete then
        Core.logLn("ISRemoveBurntVehicle not loaded; scrapping a wreck will not release its room")
        return
    end

    local baseComplete = ISRemoveBurntVehicle.complete
    function ISRemoveBurntVehicle:complete()
        local vehicle = self.vehicle
        local vehicleId = vehicle and Core.vehicleId(vehicle, false)
        -- Already out of the world means unloaded, and whatever complete()
        -- does to it next, that is not a removal we can tell apart.
        local leased = vehicleId and Slots.find(vehicleId) and not vehicle:isRemovedFromWorld()

        -- Bank where it is while it can still be asked, so a tenant put out
        -- below lands where the wreck was rather than where it was last seen.
        if leased then
            Transit.notePosition(vehicle:getId())
        end

        local result = baseComplete(self)

        if leased and vehicle:isRemovedFromWorld() then
            Removal.vacate(vehicleId, "vehicle scrapped")
        end
        return result
    end
end

--- A client says an admin is about to remove this vehicle.
--
-- Only a warning, and only ever acted on once the vehicle really goes, so
-- the client is trusted with nothing. Still refused from anybody but an admin:
-- the tick below cannot tell a removal from an unload, and the window is only
-- sound while somebody is standing beside the vehicle keeping it loaded --
-- which the cheat, opened from the mechanics panel, guarantees.
function Removal.watch(player, handle)
    if not Core.tools.isAdmin(player) then
        Core.debugLn("ignored a removal notice from " .. tostring(Core.playerKey(player)))
        return false
    end
    local vehicle = handle and getVehicleById(handle)
    local vehicleId = vehicle and Core.vehicleId(vehicle, false)
    if not vehicleId or not Slots.find(vehicleId) or vehicle:isRemovedFromWorld() then
        return false
    end

    Transit.notePosition(handle)
    watched = watched or {}
    table.insert(watched, {
        vehicle = vehicle,
        vehicleId = vehicleId,
        expires = getTimestampMs() + WATCH_MS
    })
    return true
end

--- Always registered; one nil compare when nothing is being watched.
function Removal.tick()
    if not watched then
        return
    end
    local now = getTimestampMs()
    for i = #watched, 1, -1 do
        local entry = watched[i]
        if entry.vehicle:isRemovedFromWorld() then
            table.remove(watched, i)
            Removal.vacate(entry.vehicleId, "vehicle removed by an admin")
        elseif now > entry.expires then
            table.remove(watched, i)
            Core.debugLn("watched " .. tostring(entry.vehicleId) .. " and it was not removed")
        end
    end
    if #watched == 0 then
        watched = nil
    end
end

--- Deferred, like the client guards, so the vanilla class it wraps exists.
function Removal.install()
    if installed then
        return
    end
    installed = true
    hookScrap()
end

return Removal
