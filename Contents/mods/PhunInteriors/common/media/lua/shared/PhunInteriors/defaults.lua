require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The stock room sets and vehicle classes.
--
-- The coordinates below point at borrowed off-grid space so v1 can be built
-- and tested without map authoring on the critical path. Nothing here ships:
-- when the PhunInteriors map lands, only the origin and count change. That is
-- the entire point of the room set being data.
--
-- Third party mods register alongside these using the same two calls.
-- ---------------------------------------------------------------------------

local function registerDefaults()

    Core.registerRoomSet("phun.van", {
        label = "Van interior",
        source = "phuninteriors",
        -- BORROWED: replace with our own map before release
        origin = {x = 22560, y = 12060, z = 0},
        pitch = {x = 60, y = 0},
        count = 38,
        size = {w = 3, h = 4},
        spawn = {x = 1, y = 1},
        -- stand here and you are put back at the vehicle
        exits = {{x = 1, y = 0}},
        power = {x = 0, y = 0, z = 1}
    })

    Core.registerVehicleClass("phun.van", {
        source = "phuninteriors",
        roomSet = "phun.van",
        requires = {trunk = true},
        scripts = {
            "Base.Van",
            "Base.VanSeats",
            "Base.VanSeats_Space",
            "Base.VanRadio",
            "Base.VanAmbulance",
            "Base.StepVan",
            "Base.StepVanMail",
            "Base.VanMail",
            "Base.VanUtility",
            "Base.VanSpiffo"
        },
        -- Beats maintaining a literal list of every StepVan livery in the game
        match = function(vehicle)
            local script = vehicle:getScript()
            if not script then
                return false
            end
            local name = tostring(script:getName())
            return name:find("^StepVan") ~= nil or name:find("^Van") ~= nil
        end
    })

    Core.applySandboxScriptOverrides()
end

-- Register on our own ready event so third party mods can hook the same one
-- and land after us, which is what lets them override a script binding.
Events[Core.events.OnReady].Add(registerDefaults)

return Core
