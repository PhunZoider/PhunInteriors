-- compat_alife: telling an A-Life NPC's zombie body from a zombie.
--
-- The failure this guards is a friendly NPC refusing a player entry as
-- "zombies too close", so the checks that matter are that each of the three
-- markers is recognised and that a plain zombie still counts.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

local report = stubs.reporter()
local check = report.check

local installed = true
function getActivatedMods()
    return {
        contains = function(_, id)
            return installed and id == "ProjectALifeNPCs"
        end
    }
end

local function zed(data, variable)
    return {
        getModData = function()
            return data
        end,
        GetVariable = function(_, name)
            return name == "ALifeActor" and variable or ""
        end
    }
end

local ALife = require "PhunInteriors/compat_alife"

check("owned flag is an NPC", ALife.isNpc(zed({ProjectALifeOwned = true})), true)
check("actor flag is an NPC", ALife.isNpc(zed({ProjectALifeActor = true})), true)
check("animation variable is an NPC", ALife.isNpc(zed({}, "true")), true)
check("a plain zombie is not", ALife.isNpc(zed({})), false)
check("a zombie with no modData is not", ALife.isNpc(zed(nil)), false)

-- Without the mod nothing is an NPC, whatever a body happens to carry.
-- A fresh copy, because the answer is cached and the stub require keeps its
-- own module table.
installed = false
local Off = dofile(ROOT .. "/Contents/mods/PhunInteriors/common/media/lua/shared/PhunInteriors/compat_alife.lua")
check("mod absent: flags ignored", Off.isNpc(zed({ProjectALifeOwned = true})), false)

os.exit(report.finish("alife") == 0 and 0 or 1)
