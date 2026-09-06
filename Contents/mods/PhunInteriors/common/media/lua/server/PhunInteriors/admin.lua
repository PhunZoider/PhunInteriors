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
-- Groundwork for binding the interior generator to the vehicle battery, and a
-- way to settle a question the jar cannot answer.
--
-- What the jar does tell us: haveElectricity() and hasGridPower() are
-- different things. IsoLightSwitch consults both, plus isNoPower() and
-- hasBatteryPower(), and vanilla pairs them as
--
--   (AllowExteriorGenerator and square:haveElectricity()) or square:hasGridPower()
--
-- in ISVehicleMenu.lua:1088. So haveElectricity is the *generator* flag and
-- hasGridPower is the mains. setHaveElectricity therefore controls the
-- generator side, and cannot switch the mains off on its own.
--
-- What it does not tell us, and what this exists to find out: whether a
-- setHaveElectricity we write survives, or whether the engine recomputes the
-- flag on its next pass and quietly reverts us. setHaveElectricity has zero
-- uses in vanilla lua, which by the rule in CLAUDE.md means "worth checking",
-- never "works". So this writes and then reads back.
--
--     PhunInteriors.admin("power")                                -- report
--     PhunInteriors.admin("power", {roomSet = "phun.van", index = 3})
--     PhunInteriors.admin("power", {on = false})                  -- write, verify
--
-- With no slot given it reports every slot somebody is currently standing in,
-- because that is the only one guaranteed to be loaded.
-- ---------------------------------------------------------------------------

--- Is the mains still on, globally? Vanilla's own formula, from
--- ISButtonPrompt.lua:520.
local function mainsStillOn()
    local shutoff = getSandboxOptions():getElecShutModifier()
    if not shutoff or shutoff <= -1 then
        return true, "never shuts off"
    end
    local days = getGameTime():getWorldAgeHours() / 24
        + (getSandboxOptions():getTimeSinceApo() - 1) * 30
    return days < shutoff, string.format("day %.1f of %s", days, tostring(shutoff))
end

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

actions.power = function(args)
    local lines = {}
    local on, detail = mainsStillOn()
    table.insert(lines, string.format("mains: %s (%s)", on and "ON" or "off", detail))

    local targets = slotsToProbe(args)
    if #targets == 0 then
        table.insert(lines, "no slot given and nobody is inside one; " ..
            "pass roomSet and index, or stand in a room")
        return lines
    end

    -- nil means report only. Present means write it and check it stuck.
    local want = nil
    if args.on ~= nil then
        want = args.on == true or args.on == "true"
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

            local counted, elec, grid, noPower, reverted = 0, 0, 0, 0, 0
            for z = bounds.z, bounds.z + 1 do
                for x = bounds.x1, bounds.x2 do
                    for y = bounds.y1, bounds.y2 do
                        local square = getCell():getGridSquare(x, y, z)
                        if square then
                            counted = counted + 1
                            if want ~= nil then
                                square:setHaveElectricity(want)
                                -- The whole point: read it straight back.
                                if square:haveElectricity() ~= want then
                                    reverted = reverted + 1
                                end
                            end
                            if square:haveElectricity() then
                                elec = elec + 1
                            end
                            if square:hasGridPower() then
                                grid = grid + 1
                            end
                            if square:isNoPower() then
                                noPower = noPower + 1
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
                if want ~= nil then
                    table.insert(lines, string.format(
                        "  wrote haveElectricity=%s; %s",
                        tostring(want),
                        reverted == 0 and "held on every square"
                            or (reverted .. " square(s) refused it immediately")))
                    table.insert(lines, "  re-run without 'on' in a minute; if it has "
                        .. "drifted back, the engine recomputes it and we cannot hold it")
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
