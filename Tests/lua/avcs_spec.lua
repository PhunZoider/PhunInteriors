-- Avcs.refuses: whether an Another Vehicle Claim System claim keeps this
-- player out of a vehicle's interior.
--
-- The fake AVCS below mirrors the real one's contract: checkPermission
-- answers true for an unclaimed vehicle and a {permissions = ...} table for a
-- claimed one, and getSimpleBooleanPermission folds that to a boolean.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
local Core = PhunInteriors
local logged = 0
Core.logLn = function()
    logged = logged + 1
end
Core.debugLn = function()
end

local Avcs = require "PhunInteriors/avcs"
local report = stubs.reporter()
local check = report.check

local claims = {}
local public = {}
local function fakeAvcs()
    return {
        checkPermission = function(player, vehicle)
            local owner = claims[vehicle:getModData().SQLID]
            if not owner then
                return true
            end
            return {
                permissions = owner == player.name,
                ownerid = owner
            }
        end,
        getPublicPermission = function(vehicle, kind)
            return public[vehicle:getModData().SQLID .. ":" .. kind] == true
        end,
        getSimpleBooleanPermission = function(details)
            if type(details) == "boolean" then
                return true
            end
            return details.permissions == true
        end,
        -- The real one mints an id as a side effect; the guard must not call it.
        getVehicleID = function(vehicle)
            vehicle:getModData().SQLID = 999
            return 999
        end
    }
end

local function vehicle(sqlId)
    local md = {
        SQLID = sqlId
    }
    return {
        getModData = function()
            return md
        end
    }
end

local owner = {
    name = "owner"
}
local stranger = {
    name = "stranger"
}

AVCS = nil
check("without AVCS nothing is refused", Avcs.refuses(stranger, vehicle(1)), false)

AVCS = fakeAvcs()
claims[1] = "owner"

local fresh = vehicle(nil)
check("a vehicle AVCS never saw is not refused", Avcs.refuses(stranger, fresh), false)
check("asking does not mint an id", fresh:getModData().SQLID, nil)

local claimed = vehicle(1)
check("a stranger is refused a claimed vehicle", Avcs.refuses(stranger, claimed), true)
check("the owner is let in", Avcs.refuses(owner, claimed), false)
check("an unclaimed id is not refused", Avcs.refuses(stranger, vehicle(2)), false)

public["1:AllowPassenger"] = true
check("public passengers do not open the room", Avcs.refuses(stranger, claimed), true)
public["1:AllowOpeningTrunk"] = true
check("a public trunk opens the room", Avcs.refuses(stranger, claimed), false)
public["1:AllowOpeningTrunk"] = nil

AVCS.checkPermission = function()
    error("owner missing from dbByPlayerID")
end
logged = 0
check("an error inside AVCS fails open", Avcs.refuses(stranger, claimed), false)
check("and is logged", logged, 1)

AVCS = nil
os.exit(report.finish("avcs") == 0 and 0 or 1)
