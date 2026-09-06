if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Scrub = require "PhunInteriors/scrub"
local Manifest = require "PhunInteriors/manifest"
local Transit = require "PhunInteriors/transit"
local Admin = {}
Core.modules.admin = Admin

-- ---------------------------------------------------------------------------
-- Admin actions.
--
-- PhunServer2 is a hook, never a dependency. When it is loaded these register
-- as chat commands; when it is not, they are still reachable through the
-- client command path. This mod has no hard dependencies.
-- ---------------------------------------------------------------------------

local actions = {}

actions.list = function()
    local summary = Slots.summary()
    local lines = {}

    for _, set in ipairs(summary.sets) do
        table.insert(lines, string.format("%s: %d/%d leased (%s)",
            set.id, set.used, set.total, set.source))
    end

    -- Longest idle first, because that is the one about to expire and the one
    -- you want the id of.
    for _, lease in ipairs(summary.leases) do
        table.insert(lines, string.format("  %s -> %s#%s, idle %.1f day(s)%s%s%s",
            lease.vehicleId, lease.roomSet, lease.index, lease.idleDays,
            lease.lastUser and (", last used by " .. lease.lastUser) or "",
            lease.occupied and ", occupied now" or "",
            lease.warned and ", warned" or ""))
        -- Where an exit would put them, and whether that is a live reading or
        -- the frozen one. Nothing else surfaces this, and every exit depends
        -- on it being right.
        table.insert(lines, string.format("      vehicle at %s (%s)",
            lease.at and string.format("%d,%d,%d", lease.at.x, lease.at.y, lease.at.z)
                or "nowhere recorded",
            lease.loaded and "loaded" or "unloaded, frozen"))
    end

    table.insert(lines, string.format("quarantine: %d slot(s) awaiting scrub%s",
        summary.quarantine, summary.quarantined or ""))
    return lines
end

-- Run the lease sweep now rather than on the daily timer.
actions.sweepleases = function()
    local expired = Slots.sweepLeases()
    local lines = {"lease sweep expired " .. tostring(expired) .. " room(s)"}
    if Slots.lastSweep then
        table.insert(lines, "  " .. Slots.lastSweep)
    end
    if expired == 0 then
        table.insert(lines, "  note: entering a room renews its lease, so age it and sweep with nothing in between")
    end
    return lines
end

-- Pretend a lease has not been touched for this many days, so the sweep can
-- act on it. Pair with sweepleases to test expiry without waiting.
actions.age = function(args)
    local vehicleId = args.vehicleId
    local days = tonumber(args.days) or 999
    if not vehicleId then
        return {"age needs a vehicleId, and optionally days"}
    end
    local assignment = Slots.age(vehicleId, days)
    if not assignment then
        return {"no room is leased to " .. tostring(vehicleId)}
    end
    return {string.format("%s#%s now looks %s days idle",
        assignment.roomSet, assignment.index, tostring(days))}
end

-- Re-read the sandbox options now.
--
-- Settings are cached and refreshed on EveryTenMinutes, so changing one mid
-- session appears to do nothing for up to ten minutes. That is fine in play
-- and awful while testing: a WeightFactor change looks like a broken
-- recalculation rather than a stale cache.
actions.reload = function()
    Core.refreshSettings()
    local shown = {}
    for name in pairs(Core.defaults) do
        table.insert(shown, name)
    end
    table.sort(shown)
    local lines = {"settings re-read from sandbox options:"}
    for _, name in ipairs(shown) do
        table.insert(lines, string.format("  %s = %s", name, tostring(Core.settings[name])))
    end
    return lines
end

-- What each leased vehicle is being charged for its interior.
actions.weight = function()
    return require("PhunInteriors/weight").report()
end

actions.free = function(args)
    local vehicleId = args.vehicleId
    if not vehicleId then
        return {"free needs a vehicleId"}
    end
    if Slots.release(vehicleId, "admin") then
        return {"released the room leased to " .. tostring(vehicleId)}
    end
    return {"no room is leased to " .. tostring(vehicleId)}
end

-- ---------------------------------------------------------------------------
-- Power probe.
--
-- Groundwork for binding the interior generator to the vehicle battery, and
-- the tool that settled how B42 electricity actually works. The jar answered
-- it in the end; this reports the state so a room can be checked in game.
--
-- Three facts, all read out of the bytecode (Docs/body.pl):
--
--   haveElectricity() ignores every field. It is
--     chunk:isGeneratorPoweringSquare(x, y, z), with an early false for an
--     exterior square when AllowExteriorGenerator is off. Generator power is
--     therefore only ever real generator power.
--
--   setHaveElectricity(boolean) does not set anything. It ignores its argument
--     and calls update() on any IsoLightSwitch on the square. It is a refresh
--     with a setter's name.
--
--   hasGridPower() is (not isNoPower()) and doesPowerGridExist(), and
--     isNoPower() is isDerelict() or isUserDefinedRoom() or the square sitting
--     in a map zone of type "NoPower" or "NoPowerOrWater".
--
-- So the mains cannot be switched off from Lua, but it can be switched off on
-- the map: a NoPower zone painted over the interior block makes hasGridPower
-- false there for good, leaving the generator as the only source. That is a
-- job for whoever builds the map, and this reports whether they have done it.
--
--     PhunInteriors.admin("power")
--     PhunInteriors.admin("power", {roomSet = "phun.van", index = 3})
--
-- With no slot it reports every slot somebody is standing in, because that is
-- the only one guaranteed to be loaded.
-- ---------------------------------------------------------------------------

--- The slots worth reporting on: the one asked for, else whatever is occupied.
local function slotsToProbe(args)
    local out = {}
    if args.roomSet and args.index then
        table.insert(out, {roomSet = args.roomSet, index = tonumber(args.index)})
        return out
    end
    for _, occupancy in pairs(Core.occupants) do
        table.insert(out, {roomSet = occupancy.roomSet, index = occupancy.index})
    end
    return out
end

--- The generator on a square, if there is one.
local function generatorOn(square)
    local objects = square and square:getObjects()
    if not objects then
        return nil
    end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and instanceof(object, "IsoGenerator") then
            return object
        end
    end
    return nil
end

actions.power = function(args)
    local lines = {}

    -- The engine's own test, the one hasGridPower calls, rather than a
    -- reimplementation of the shutoff arithmetic.
    table.insert(lines, string.format("power grid exists: %s (ElecShutModifier %s)",
        tostring(getSandboxOptions():doesPowerGridExist()),
        tostring(getSandboxOptions():getElecShutModifier())))

    local targets = slotsToProbe(args)
    if #targets == 0 then
        table.insert(lines, "no slot given and nobody is inside one; " ..
            "pass roomSet and index, or stand in a room")
        return lines
    end

    for _, target in ipairs(targets) do
        local set = Core.roomSets[target.roomSet]
        if not set then
            table.insert(lines, "unknown room set " .. tostring(target.roomSet))
        else
            local bounds = Core.slotBounds(set, target.index)
            local power = Core.slotPower(set, target.index)
            table.insert(lines, string.format("%s#%s, power square %d,%d,%d",
                target.roomSet, target.index, power.x, power.y, power.z))

            local counted, elec, grid, noPower, derelict, userRoom = 0, 0, 0, 0, 0, 0
            local zones = {}
            for z = bounds.z, bounds.z + 1 do
                for x = bounds.x1, bounds.x2 do
                    for y = bounds.y1, bounds.y2 do
                        local square = getCell():getGridSquare(x, y, z)
                        if square then
                            counted = counted + 1
                            if square:haveElectricity() then elec = elec + 1 end
                            if square:hasGridPower() then grid = grid + 1 end
                            if square:isNoPower() then noPower = noPower + 1 end
                            if square:isDerelict() then derelict = derelict + 1 end
                            if square:isUserDefinedRoom() then userRoom = userRoom + 1 end
                            local zone = square:getZoneType()
                            if zone and zone ~= "" then
                                zones[zone] = (zones[zone] or 0) + 1
                            end
                        end
                    end
                end
            end

            if counted == 0 then
                table.insert(lines, "  chunk is not loaded, nothing to read")
            else
                table.insert(lines, string.format(
                    "  %d square(s): haveElectricity %d, hasGridPower %d, isNoPower %d",
                    counted, elec, grid, noPower))
                -- The three things isNoPower is made of, so a room that is
                -- still on the mains says why.
                table.insert(lines, string.format(
                    "  isDerelict %d, isUserDefinedRoom %d, zones: %s",
                    derelict, userRoom,
                    Core.tools.isEmpty(zones) and "none" or (function()
                        local names = {}
                        for name, n in pairs(zones) do
                            table.insert(names, name .. " x" .. n)
                        end
                        return table.concat(names, ", ")
                    end)()))

                if noPower == 0 and getSandboxOptions():doesPowerGridExist() then
                    table.insert(lines, "  NOTE: on the mains. Paint a NoPower zone "
                        .. "over this block on the map and the generator becomes "
                        .. "the only source.")
                end

                local generatorSquare = getCell():getGridSquare(power.x, power.y, power.z)
                local generator = generatorOn(generatorSquare)
                if not generatorSquare then
                    table.insert(lines, "  power square is not loaded")
                elseif generator then
                    table.insert(lines, string.format(
                        "  generator: activated %s, fuel %.1f/%.1f, condition %d",
                        tostring(generator:isActivated()), generator:getFuel(),
                        generator:getMaxFuel(), generator:getCondition()))
                else
                    table.insert(lines, "  no generator on the power square")
                end
            end
        end
    end

    return lines
end

actions.scrub = function(args)
    if args.roomSet and args.index then
        local ok, reason = Scrub.slot(args.roomSet, tonumber(args.index))
        return {ok and "scrubbed" or ("could not scrub: " .. tostring(reason))}
    end
    local done = Scrub.processQueue(10)
    return {"scrubbed " .. done .. " quarantined slot(s)"}
end

actions.evict = function(args)
    local username = args.username
    if not username then
        return {"evict needs a username"}
    end
    local player = Core.tools.getPlayerByUsername(username)
    if not player then
        return {username .. " is not online"}
    end
    local left, why = Transit.leave(player, "admin")
    if left then
        return {"evicted " .. username}
    end
    -- Not always "not inside": the exit refuses a moving vehicle with no free
    -- seat, and a vehicle it cannot place. Reporting those as "not inside"
    -- sends an admin looking for the wrong problem.
    return {"could not evict " .. username .. ": " .. tostring(why)}
end

-- What every captured blueprint weighs. This is the measurement the design
-- note asks for: the estimates there were derived from room dimensions, and
-- nothing had ever been captured to check them against.
actions.manifests = function()
    return Manifest.report()
end

-- Rescan one slot you are standing in. Targets a slot rather than a room set
-- because there is no golden slot any more, and a blueprint is only ever as
-- good as the room it was read from.
actions.remanifest = function(args)
    local roomSet = args.roomSet
    local index = tonumber(args.index)
    if not roomSet or not index then
        return {"remanifest needs a roomSet and an index"}
    end
    if Core.shippedBlueprint(roomSet, index) then
        return {roomSet .. "#" .. index .. " ships a blueprint; rescanning would be ignored"}
    end
    Manifest.forgetSlot(roomSet, index)
    local captured, reason = Manifest.captureSlot(roomSet, index, true)
    if captured then
        return {"recaptured " .. roomSet .. "#" .. index .. ": " .. captured.objectCount .. " objects"}
    end
    return {"could not capture " .. roomSet .. "#" .. index .. ": " .. tostring(reason)}
end

function Admin.run(action, args)
    local handler = actions[action]
    if not handler then
        local names = {}
        for name in pairs(actions) do
            table.insert(names, name)
        end
        table.sort(names)
        return {"unknown action. try: " .. table.concat(names, ", ")}
    end
    local ok, result = pcall(handler, args)
    if not ok then
        Core.logLn("admin action " .. tostring(action) .. " failed: " .. tostring(result))
        return {"that failed, check the server log"}
    end
    return result
end

--- Soft hook into PhunServer2 if it happens to be loaded.
function Admin.registerChatCommands()
    if not PhunServer2 or not PhunServer2.registerCommand then
        Core.debugLn("PhunServer2 not present, skipping chat command registration")
        return false
    end

    PhunServer2.registerCommand("interiors", {
        adminOnly = true,
        help = function()
            return getText("IGUI_PhunInteriors_AdminUsage")
        end,
        action = function(player, arguments)
            local parts = {}
            for word in string.gmatch(arguments or "", "%S+") do
                table.insert(parts, word)
            end
            local result = Admin.run(parts[1] or "list", {
                vehicleId = parts[2],
                roomSet = parts[2],
                index = parts[3],
                username = parts[2]
            })
            for _, line in ipairs(result) do
                Core.logLn(line)
            end
            return result
        end
    })

    Core.logLn("registered /interiors with PhunServer2")
    return true
end

return Admin
