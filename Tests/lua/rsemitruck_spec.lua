-- The W900 Semi-Truck patch: on a truck rSemiTruck's payload damping owns,
-- the room's weight goes in as their payload rather than as our own setMass.
--
-- The fake MSW_MassUtil mirrors the real one's shape: desiredMass reaches
-- computePayload through the global table, which is the only reason the wrap
-- can work, and isTargetVehicle is a script whitelist.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end
Core.settings.WeightFactor = 50

local report = stubs.reporter()
local check = report.check

local function vehicle(script)
    local v = {md = {}, mass = 1000, initial = 1000, totals = 0, sets = 0}
    function v:getModData() return self.md end
    function v:getScript() return {getName = function() return script end} end
    function v:getMass() return self.mass end
    function v:setMass(m) self.mass = m; self.sets = self.sets + 1 end
    function v:getInitialMass() return self.initial end
    function v:setInitialMass(m) self.initial = m end
    function v:updateTotalMass() self.totals = self.totals + 1 end
    return v
end

local Semi = require "PhunInteriors/compat_rsemitruck"
local Weight = require "PhunInteriors/weight"

check("without rSemiTruck nothing is managed", Semi.manages(vehicle("SemiTruckBox")), false)

local plain = vehicle("Van")
Weight.apply(plain, 100)
check("without rSemiTruck the additive path runs", plain.mass, 1050)

MSW_MassUtil = {
    isTargetVehicle = function(v)
        local name = v:getScript():getName()
        if name == "Broken" then
            error("boom")
        end
        return name == "SemiTruckBox"
    end,
    computePayload = function()
        return 100, 20, 120
    end
}
function MSW_MassUtil.desiredMass(v, factor)
    local _, _, payload = MSW_MassUtil.computePayload(v)
    return 1000 + payload * factor
end

local box = vehicle("SemiTruckBox")
check("a whitelisted truck is managed", Semi.manages(box), true)
check("one it does not list is not", Semi.manages(vehicle("Van")), false)
check("an error inside isTargetVehicle is not", Semi.manages(vehicle("Broken")), false)
check("installing twice does not stack", Semi.install() and Semi.install(), true)

check("no room weight leaves their payload alone", MSW_MassUtil.desiredMass(box, 0.5), 1060)

Weight.apply(box, 100)
check("the managed truck's mass is not written", box.sets, 0)
check("nor recomputed", box.totals, 0)
check("the room is stored as payload", Semi.payloadOf(box), 50)
check("and their payload carries it", select(3, MSW_MassUtil.computePayload(box)), 170)
check("as cargo", (MSW_MassUtil.computePayload(box)), 150)
check("so their desired mass includes it, damped", MSW_MassUtil.desiredMass(box, 0.5), 1085)

Weight.apply(box, 0)
check("an emptied room clears the payload", box.md[Core.consts.payloadDeltaKey], nil)
check("and their desired mass falls back", MSW_MassUtil.desiredMass(box, 0.5), 1060)

local old = vehicle("SemiTruckBox")
old.md[Core.consts.massDeltaKey] = 40
old.mass, old.initial = 1040, 1040
Weight.apply(old, 100)
check("a legacy delta comes off the initial mass", old.initial, 1000)
check("and off the mass", old.mass, 1000)
check("and is forgotten", old.md[Core.consts.massDeltaKey], nil)
check("and the room goes in as payload instead", Semi.payloadOf(old), 50)

local van = vehicle("Van")
Weight.apply(van, 100)
check("an unlisted vehicle still takes the additive path", van.mass, 1050)
check("with no payload stored", van.md[Core.consts.payloadDeltaKey], nil)

MSW_MassUtil = nil
os.exit(report.finish("rsemitruck") == 0 and 0 or 1)
