-- Transit.exitTax: how many zombies a visit gathers outside its vehicle.
--
-- The point of the checks is the ceiling. This is meant to be a nudge, so the
-- ones that matter are that a short visit costs nothing and that no visit,
-- however long, ever costs more than the cap.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

local Transit = require "PhunInteriors/transit"
local report = stubs.reporter()
local check = report.check

local function settings(on, rate, cap)
    Core.settings.ExitTax = on
    Core.settings.ExitTaxGrowth = rate
    Core.settings.ExitTaxCap = cap
end

settings(true, 4, 3)
check("no time inside gathers nothing", Transit.exitTax(0), 0)
check("an hour inside gathers nothing", Transit.exitTax(1), 0)
check("five hours gathers nothing yet", Transit.exitTax(5), 0)
check("six hours gathers one", Transit.exitTax(6), 1)
check("a night gathers one", Transit.exitTax(10), 1)
check("eighteen hours gathers three", Transit.exitTax(18), 3)
check("a day is held to the cap", Transit.exitTax(24), 3)
check("a month is held to the cap", Transit.exitTax(24 * 30), 3)

check("negative time gathers nothing", Transit.exitTax(-5), 0)
check("nil time gathers nothing", Transit.exitTax(nil), 0)

settings(false, 4, 3)
check("off gathers nothing", Transit.exitTax(24 * 30), 0)

settings(true, 4, 0)
check("a cap of 0 gathers nothing", Transit.exitTax(24 * 30), 0)

settings(true, 0, 3)
check("a rate of 0 gathers nothing", Transit.exitTax(24 * 30), 0)

settings(true, 48, 20)
check("the highest rate is still held to its cap", Transit.exitTax(24 * 30), 20)

os.exit(report.finish("exittax") == 0 and 0 or 1)
