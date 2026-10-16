-- Zones.read / Zones.heal: putting back power and water zones a save lost.
--
-- The checks that matter: a zone already held is not registered twice, a
-- missing one is, a refusal by registerZone is reported rather than counted as
-- healed (it returns a zone either way), and the `objects` global is left as
-- it was found, because vanilla's loader and other maps use the same name.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
local Core = PhunInteriors
local logged = {}
Core.logLn = function(s)
    table.insert(logged, s)
end
Core.debugLn = function()
end

local Zones = require "PhunInteriors/zones"
local report = stubs.reporter()
local check = report.check

-- The file on disk, as objects.lua would set the global
local fileBody
local exists = true
function fileExists()
    return exists
end
function reloadLuaFile()
    if fileBody == "throw" then
        error("bad entry")
    end
    objects = fileBody
end

-- A meta grid holding a list of zones, and a registerZone that refuses what
-- the real one refuses for size
local held, registered
local function reset(zones)
    held, registered = zones or {}, 0
end
function getWorld()
    return {
        getMetaGrid = function()
            return {
                getZoneWithBoundsAndType = function(_, x, y, z, w, h, t)
                    for _, k in ipairs(held) do
                        if k.x == x and k.y == y and k.z == z and k.width == w and k.height == h and k.type == t then
                            return k
                        end
                    end
                    return nil
                end
            }
        end,
        registerZone = function(_, name, t, x, y, z, w, h)
            registered = registered + 1
            local zone = {name = name, type = t, x = x, y = y, z = z, width = w, height = h}
            if w <= 1202 and h <= 1202 then
                table.insert(held, zone)
            end
            return zone
        end
    }
end

local A = {name = "Waterless", type = "NoPowerOrWater", x = 22272, y = 11776, z = 0, width = 512, height = 768}
local B = {name = "Waterless", type = "NoPowerOrWater", x = 22784, y = 11776, z = 0, width = 768, height = 1024}
local C = {name = "Waterless", type = "NoPowerOrWater", x = 23552, y = 11776, z = 0, width = 256, height = 256}
local function copy(t)
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return c
end

-- reading
fileBody = {A, B, C,
            {name = "x", type = "ZombiesType", x = 1, y = 1, z = 0, width = 2, height = 2},
            {name = "p", type = "NoPower", geometry = "polygon", points = {}}}
objects = "theirs"
local list = Zones.read()
check("reads the healable rectangles", #list, 3)
check("leaves the objects global as found", objects, "theirs")
check("copies the fields", list[3].x, 23552)

fileBody = "throw"
local none, err = Zones.read()
check("a throwing file reads as nil", none, nil)
check("and says why", err ~= nil, true)
check("objects restored after a throw", objects, "theirs")

exists = false
check("a missing file reads as nil", (Zones.read()), nil)
exists = true

-- healing
fileBody = {A, B, C}
reset({copy(A), copy(B), copy(C)})
local had, healed, failed = Zones.heal(Zones.read())
check("all held: none registered", registered, 0)
check("all held: counted", had, 3)
check("all held: none healed", healed, 0)

-- the reported case: a save from before the third zone existed
reset({copy(A), copy(B)})
had, healed, failed = Zones.heal(Zones.read())
check("stale save: one registered", registered, 1)
check("stale save: healed", healed, 1)
check("stale save: now held", #held, 3)
check("stale save: nothing failed", #failed, 0)

-- a second pass finds it and does nothing
had, healed = Zones.heal(Zones.read())
check("second pass registers nothing", registered, 1)
check("second pass healed none", healed, 0)

-- a refusal is a failure, not a heal, even though registerZone returned a zone
fileBody = {{name = "Waterless", type = "NoPowerOrWater", x = 0, y = 0, z = 0, width = 1280, height = 1024}}
reset({})
had, healed, failed = Zones.heal(Zones.read())
check("refused: attempted", registered, 1)
check("refused: not counted healed", healed, 0)
check("refused: reported", #failed, 1)

-- logging: silent when nothing is missing
fileBody = {A}
reset({copy(A)})
logged = {}
Zones.check()
check("silent when all present", #logged, 0)
reset({})
Zones.check()
check("says so when it heals", #logged, 1)

os.exit(report.finish("zones") == 0 and 0 or 1)
