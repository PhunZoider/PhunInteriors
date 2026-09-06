if isServer() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/client_main"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Keeping the server's idea of where a leased vehicle is.
--
-- The exit puts a player back at their vehicle, and at the moment they ask to
-- leave the vehicle is almost always unloaded -- nobody has been near it since
-- they went inside. An unloaded vehicle cannot be looked up, so the server has
-- to answer from a stored position.
--
-- That is only safe because of one fact: an unloaded vehicle cannot move. So a
-- stored position is not stale data that might be wrong, it is frozen truth --
-- provided it was accurate at the instant the vehicle unloaded. Keeping it
-- accurate is this file's whole job.
--
-- The server cannot do this for itself. getCell():getVehicles() returns a
-- java.util.Set with no get(i), so loaded vehicles cannot be enumerated from
-- Lua at all, and sweeping squares for every lease once a second is not free.
-- The driver's client, by contrast, already has the vehicle in hand.
--
-- It sends the vehicle *id* and nothing else. The server looks the vehicle up
-- and reads the position itself, so this is a nudge saying "look now", never a
-- claim about where anything is, and there is nothing here for a client to
-- lie about.
--
-- Shape borrowed from RV Interior, which solved this problem first.
-- ---------------------------------------------------------------------------

-- Below this the vehicle counts as parked. RV Interior's figure.
local STATIONARY_KMH = 0.2
-- Ticks between checks. This runs on every player update while driving, so it
-- wants to be cheap; a check every ~1.6s is plenty for a 70 tile threshold.
local CHECK_TICKS = 100
-- How far it may travel before we refresh. Sits just inside the measured 61-120
-- tile chunk load radius, so a position this stale still finds the vehicle.
local RESEND_TILES = 70

local watching = nil

local function stopWatching()
    if watching then
        Events.OnPlayerUpdate.Remove(watching)
        watching = nil
    end
end

--- Tell the server to go and look at this vehicle, if it is one of ours.
--
-- The client cannot tell whether a vehicle actually holds a lease -- that
-- lives in server side modData -- so it filters on the vehicle *class*, which
-- the registry knows on both sides, and the server filters on the lease.
local function pushPosition(vehicle)
    if not vehicle or not Core.classForVehicle(vehicle) then
        return
    end
    Core.dispatch(Core.commands.updatePosition, {id = vehicle:getId()})
end

--- Start watching, if this player just took the wheel of something we care
--- about. Called on entering a vehicle and on changing seats.
local function watch(player)
    -- Only ever our own driving. A remote player's vehicle is their client's
    -- job to report, and duplicating it just doubles the traffic.
    if not player or not player:isLocalPlayer() then
        return
    end
    local vehicle = player:getVehicle()
    if not vehicle or not vehicle:isDriver(player) then
        return
    end
    -- A trailer with an interior is worth following even when the thing towing
    -- it has none of its own.
    if not Core.classForVehicle(vehicle) and not Core.classForVehicle(vehicle:getVehicleTowing()) then
        return
    end

    -- Never stack two watchers; changing seats calls this again.
    stopWatching()

    local delay = 0
    local lastSent = nil

    watching = function(updated)
        -- OnPlayerUpdate fires for every local player, so in split screen this
        -- would otherwise run the driver's check on the passenger's ticks too.
        if updated and updated ~= player then
            return
        end
        if delay > 0 then
            delay = delay - 1
            return
        end
        delay = CHECK_TICKS

        local speed = math.abs(vehicle:getCurrentSpeedKmHour())
        local moving = speed >= STATIONARY_KMH
        local far = not lastSent or lastSent:DistTo(player) > RESEND_TILES

        -- Refresh while it is moving, and once more when it stops.
        --
        -- The stop is the one that matters. Everything downstream trusts the
        -- stored position because an unloaded vehicle cannot move, and this is
        -- what makes the last stored position the true resting position. The
        -- sends while moving only stop it drifting so far that a player
        -- exiting mid journey lands out of range of it.
        if (moving and far) or (not moving and lastSent) then
            pushPosition(vehicle)
            pushPosition(vehicle:getVehicleTowing())
            lastSent = moving and vehicle:getSquare() or nil
        end

        -- Out of the driver's seat and the final position is in. Nothing left
        -- to watch until they drive again.
        if not vehicle:isDriver(player) and not lastSent then
            stopWatching()
        end
    end

    Events.OnPlayerUpdate.Add(watching)
end

--- Deferred, like the destroy guards.
--
-- OnSwitchVehicleSeat is not an engine event: vanilla registers it from
-- ISVehicleDashboard.lua, so it does not exist while our client folder is
-- still loading. Hooking it at file scope would silently do nothing.
function Client.installTracker()
    Events.OnEnterVehicle.Add(watch)
    if Events.OnSwitchVehicleSeat then
        Events.OnSwitchVehicleSeat.Add(watch)
    else
        Core.logLn("OnSwitchVehicleSeat not registered; position tracking will "
            .. "miss a player who slides into the driver's seat")
    end
end
