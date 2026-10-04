if isClient() then
    return
end
local Core = PhunInteriors
local Avcs = {}
Core.modules.avcs = Avcs

-- ---------------------------------------------------------------------------
-- Compatibility: Another Vehicle Claim System (Workshop 2957935793), and with
-- it the Tsar's Common Library patch for it (2965124692), which adds nothing
-- we need to ask about.
--
-- AVCS guards a claimed vehicle by wrapping vanilla's timed actions: entering
-- a seat, opening the trunk, siphoning, taking parts. Walking into the
-- interior is none of those -- it is our own action and a teleport -- so
-- without this a stranger could step into the back of a claimed van and help
-- themselves to everything the owner keeps in its room.
--
-- The room is the vehicle's cargo space, so it follows the TRUNK: the
-- vehicle's public AllowOpeningTrunk opens it to everybody, and otherwise it
-- is AVCS.checkPermission, which already answers owner, faction, safehouse
-- and admin (ManipulateVehicle) exactly as AVCS does for its own actions. No
-- exemption of ours is written here, for the tent lock's reason.
--
-- A soft hook. AVCS is a global it defines at load, so it is looked up at
-- call time and its absence means "no claims". Only entry is gated: leaving
-- is always allowed, and a tenant inside when the vehicle is claimed walks
-- out normally.
-- ---------------------------------------------------------------------------

local PUBLIC = "AllowOpeningTrunk"

--- The AVCS table when that mod is running, else nil.
function Avcs.active()
    local avcs = AVCS
    if type(avcs) ~= "table" or type(avcs.checkPermission) ~= "function" then
        return nil
    end
    return avcs
end

--- Whether a claim keeps this player out of this vehicle's interior.
--
-- Reads the SQLID straight off the vehicle's modData rather than through
-- AVCS.getVehicleID, because that call MINTS an id for a vehicle that has
-- none, and asking whether a vehicle is claimed should not change it. No id
-- means AVCS has never seen it, which means nobody has claimed it.
--
-- Fails OPEN on an error inside AVCS, and says so in the log: a soft hook
-- whose failure locked every vehicle room on the server, owners included,
-- would be the worse fault.
function Avcs.refuses(player, vehicle)
    local avcs = Avcs.active()
    if not avcs or not player or not vehicle then
        return false
    end

    local ok, refused = pcall(function()
        local md = vehicle:getModData()
        local sqlId = md and md.SQLID
        if not sqlId then
            return false
        end
        if avcs.getPublicPermission and avcs.getPublicPermission(vehicle, PUBLIC) then
            return false
        end
        local details = avcs.checkPermission(player, vehicle)
        if avcs.getSimpleBooleanPermission then
            return not avcs.getSimpleBooleanPermission(details)
        end
        return type(details) == "table" and details.permissions ~= true
    end)

    if not ok then
        Core.logLn("AVCS permission check failed, letting the entry through: " .. tostring(refused))
        return false
    end
    return refused == true
end

return Avcs
