-- Compatibility: W900 Semi-Truck (rSemiTruck, workshop 3409472393).
--
-- rSemiTruck runs its own mass system, "payload damping", over a whitelist of
-- its scripts (MSW_VehicleFilter: SemiTruckBox, SemiTruckBox_mil,
-- SemiTrailerVan, SemiTrailerVan_mil, SemiTrailerContainer). It holds each at
-- script mass plus PayloadFactor (0.65, with no sandbox option to change it)
-- of the payload, capped per script, because at their true mass these trucks
-- spike in the physics: its own changelog records them being kicked upward.
-- It writes ABSOLUTE masses, server side on OnPlayerMove and a tick, client
-- side on a tick, and refuses to raise one while the vehicle is physically
-- active.
--
-- Weight.apply's additive delta cannot live beside that. Its updateTotalMass()
-- recomputes the uncapped mass -- rSemiTruck's own comment says so, and it
-- re-caps after every call it makes itself -- on a truck that has just
-- reloaded, as the tenant lands beside it. Reported in game as the box truck's
-- hood and rear door going missing on exit and a crash minutes later. And the
-- next absolute write drops our delta anyway, so the following exit subtracts
-- a delta that is no longer in the mass.
--
-- So for those vehicles the room joins THEIR payload instead. Every number
-- their system uses comes from one global, MSW_MassUtil.computePayload, reached
-- through the table by desiredMass and by both damping passes; the wrap below
-- adds the room's weight to it. The room then counts on a semi exactly as the
-- cargo in its box would: damped by their factor, held to their cap, and
-- applied by their code under their lock. Their acceptance test only lets a
-- mass rise through when the payload rose, and it reads the payload from the
-- same function, so ours qualifies. Double damping (WeightFactor, then 0.65)
-- is deliberate: dividing their factor back out would rank a room above their
-- own cargo in a stability system we do not own.
--
-- The delta is vehicle modData, which never reaches a client, so their CLIENT
-- pass computes without it. Their server recomputes rather than trusting the
-- client's number, so the server's mass is right. Whether the driver's physics
-- feels it on a dedicated server is the same open question as our weight on
-- any vehicle.
--
-- Not a dependency. Installs when MSW_MassUtil exists, which can be after this
-- file loads, so it is retried on the boot events and on first use. Stands
-- down to Weight.apply's own path, per vehicle, whenever the wrap is not in
-- place or isTargetVehicle does not say yes -- including when rSemiTruck has
-- switched its own damping off for RealisticCarPhysics.
require "PhunInteriors/core"
local Core = PhunInteriors

local M = {
    wrapped = false,
    wrapper = nil
}
Core.compat.rsemitruck = M

--- The room weight this vehicle is carrying as rSemiTruck payload.
function M.payloadOf(vehicle)
    local ok, value = pcall(function()
        return vehicle:getModData()[Core.consts.payloadDeltaKey]
    end)
    return ok and tonumber(value) or 0
end

local function wrap(original)
    return function(vehicle, ...)
        local cargo, parts, total = original(vehicle, ...)
        local extra = vehicle and M.payloadOf(vehicle) or 0
        if extra > 0 then
            return (tonumber(cargo) or 0) + extra, parts, (tonumber(total) or 0) + extra
        end
        return cargo, parts, total
    end
end

--- Wrap computePayload, once. True when the wrap is in place.
function M.install()
    local util = rawget(_G, "MSW_MassUtil")
    if type(util) ~= "table" or type(util.computePayload) ~= "function" then
        return false
    end
    if M.wrapped and util.computePayload == M.wrapper then
        return true
    end
    -- Ours came off (their file re-ran, or something else replaced it); wrap
    -- whatever is there now rather than stacking on a stale original.
    M.wrapper = wrap(util.computePayload)
    util.computePayload = M.wrapper
    M.wrapped = true
    Core.logLn("compat: W900 Semi-Truck found, room weight joins its payload damping on its trucks")
    return true
end

--- Whether rSemiTruck owns this vehicle's mass, so the room goes in as payload.
function M.manages(vehicle)
    if not vehicle or not M.install() then
        return false
    end
    local util = rawget(_G, "MSW_MassUtil")
    if type(util.isTargetVehicle) ~= "function" then
        return false
    end
    local ok, yes = pcall(util.isTargetVehicle, vehicle)
    return ok and yes == true
end

if Events then
    if Events.OnInitGlobalModData then
        Events.OnInitGlobalModData.Add(M.install)
    end
    if Events.OnGameStart then
        Events.OnGameStart.Add(M.install)
    end
end
M.install()

return M
