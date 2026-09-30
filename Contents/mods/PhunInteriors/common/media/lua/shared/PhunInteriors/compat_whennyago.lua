-- Compatibility: Whennyago Initiative (workshop 3790153201).
--
-- Whennyago charges its roof solar and runs its rear generator from an
-- EveryOneMinute handler in media/lua/server/WhennyagoInitiative_VehicleUse.lua.
-- The work is fine. Finding the vehicles is not:
--
--   * It walks a 201x201 square grid around every local player, about 40,000
--     getGridSquare calls each wrapped in a fresh pcall closure, every in-game
--     minute. On a short day length that is a steady stream of garbage, and it
--     was sat right next to an out of memory crash on the test server.
--   * The file has no isClient() guard, so in multiplayer every CLIENT runs it
--     and transmits what it did, while the dedicated server, which has no
--     local players, finds nothing. Two players near one RV charge it twice.
--   * Its fallback, cell:getVehicles(), calls get(i) on a java Set and so never
--     returns anything.
--   * The engine ALSO calls the same two functions, as those parts' script
--     `update` hooks, whenever vehicle:needPartsUpdate() is set (somebody
--     seated, engine state changed). While it is, both run, and the battery is
--     charged and the generator's fuel burned twice.
--
-- The handler cannot simply be removed. needPartsUpdate is cleared by vanilla's
-- Engine update once the engine is cold and nobody is at the wheel, so for a
-- PARKED vehicle, which is the only time the generator runs, the minute handler
-- is the only thing driving either part. (VehicleParts.update,
-- VehicleParts.updatePart, BaseVehicle.update and setPassenger, read from the
-- bytecode.) So it is REPLACED:
--
--   * server and single player only. A multiplayer client does nothing.
--   * vehicles come from cell:getVehicles():iterator(), not a square sweep.
--     Iterator is exposed, and Whennyago's own client code iterates this Set.
--   * a vehicle the engine is already updating is left to the engine.
--   * a part driven here has its lastUpdated moved on, so the engine's catch
--     up when somebody next climbs in does not charge the same hours again.
--
-- Protections. The patch stands down, and Whennyago's own handler runs exactly
-- as shipped from then on, as soon as any of these stops holding:
--   * WhennyagoInitiative.Update.RoofSolarUpgrade and RearGeneratorBoxUpgrade
--     are both functions.
--   * every Whennyago vehicle seen still wires exactly those two names as its
--     parts' update hooks, read off the live part (getLuaFunction). Checked on
--     clients too, so both sides reach the same verdict.
--   * a pass does not throw (a failed iterator lands here).
-- It also logs once when the handler has moved in the file, meaning Whennyago
-- has been updated since this was checked, and once when Whennyago is active
-- but never registered the handler at all, meaning there is nothing to patch.
-- PhunInteriors.WhennyagoPatch turns it off, live.
--
-- PhunFixes carries the same patch for servers without PhunInteriors, and
-- leaves the handler alone when Core.compat.whennyago.hooked is set. Keep the
-- two in step.
require "PhunInteriors/core"
local Core = PhunInteriors

local MOD_ID = "WhennyagoInitiative"
local SOURCE_FILE = "WhennyagoInitiative_VehicleUse.lua"
-- getFirstLineOfClosure of the handler in the release this was checked against
local KNOWN_LINE = 648
local SCRIPT_PREFIX = "WhennyagoInitiative"
local PARTS = {
    RoofSolarUpgrade = "WhennyagoInitiative.Update.RoofSolarUpgrade",
    RearGeneratorBoxUpgrade = "WhennyagoInitiative.Update.RearGeneratorBoxUpgrade"
}

local state = {
    active = false, -- Whennyago is installed
    hooked = false, -- our EveryOneMinute.Add is in place
    found = false, -- its handler came through it
    line = nil,
    standDown = nil, -- why we handed back, once we have
    driven = 0 -- parts updated on the last pass
}
Core.compat.whennyago = state

local function isActive()
    local ok, yes = pcall(function()
        local mods = getActivatedMods()
        return mods and mods:contains(MOD_ID)
    end)
    return ok and yes == true
end

local function standDown(reason)
    if state.standDown then
        return
    end
    state.standDown = reason
    Core.logLn("compat: Whennyago Initiative patch stood down, its own handler runs as shipped: " .. reason)
end

local function powerFunctions()
    local update = WhennyagoInitiative and WhennyagoInitiative.Update
    if update and type(update.RoofSolarUpgrade) == "function" and type(update.RearGeneratorBoxUpgrade) ==
        "function" then
        return update
    end
end

-- Checks one vehicle's wiring and, when drive is set, updates its installed
-- upgrades for one minute. Returns how many parts it updated.
local function visit(vehicle, drive, now, update)
    local script = vehicle:getScript()
    local name = script and script:getName()
    if not name or name:sub(1, #SCRIPT_PREFIX) ~= SCRIPT_PREFIX then
        return 0
    end
    local count = 0
    for partId, hook in pairs(PARTS) do
        -- a variant without the part (the burnt shell) is fine; a part wired
        -- to something else is not
        local part = vehicle:getPartById(partId)
        if part then
            local wired = part:getLuaFunction("update")
            if wired ~= hook then
                standDown(name .. "." .. partId .. " update hook is " .. tostring(wired) .. ", expected " .. hook)
                return count
            end
            if drive and part:getInventoryItem() then
                update[partId](vehicle, part, 1)
                part:setLastUpdated(now)
                count = count + 1
            end
        end
    end
    return count
end

local function pass()
    local update = powerFunctions()
    if not update then
        standDown("WhennyagoInitiative.Update no longer has both power functions")
        return
    end
    local cell = getCell()
    local vehicles = cell and cell:getVehicles()
    if not vehicles then
        return
    end
    local authority = not isClient()
    local now = getGameTime():getWorldAgeHours()
    local count = 0
    local it = vehicles:iterator()
    while it:hasNext() do
        local vehicle = it:next()
        if vehicle then
            count = count + visit(vehicle, authority and not vehicle:needPartsUpdate(), now, update)
            if state.standDown then
                return
            end
        end
    end
    state.driven = count
end

local function replace(original)
    return function(...)
        if Core.settings.WhennyagoPatch == false or state.standDown then
            return original(...)
        end
        local ok, err = pcall(pass)
        if not ok then
            standDown("the replacement pass failed: " .. tostring(err))
        end
        if state.standDown then
            -- this minute too, so nothing is skipped
            return original(...)
        end
    end
end

local function isTarget(fn)
    local ok, file = pcall(getFilenameOfClosure, fn)
    return ok and type(file) == "string" and file:find(SOURCE_FILE, 1, true) ~= nil
end

local function install()
    local ev = Events.EveryOneMinute
    if not (ev and ev.Add and ev.Remove) then
        return
    end
    local add, remove = ev.Add, ev.Remove
    local wrappers = {} -- original -> replacement, so Remove(original) still works

    ev.Add = function(fn)
        if type(fn) == "function" and isTarget(fn) then
            local w = wrappers[fn]
            if not w then
                w = replace(fn)
                wrappers[fn] = w
                state.found = true
                local ok, line = pcall(getFirstLineOfClosure, fn)
                state.line = ok and line or nil
                if state.line == KNOWN_LINE then
                    Core.logLn("compat: replacing Whennyago Initiative's minute handler (PhunInteriors.WhennyagoPatch)")
                else
                    Core.logLn("compat: replacing Whennyago Initiative's minute handler, which has moved to line " ..
                                   tostring(state.line) .. " (checked at " .. KNOWN_LINE ..
                                   "), so the mod has changed since. Patching while its hooks check out; turn off " ..
                                   "PhunInteriors.WhennyagoPatch if its solar or generator misbehaves.")
                end
            end
            return add(w)
        end
        return add(fn)
    end

    ev.Remove = function(fn)
        local w = wrappers[fn]
        if w then
            wrappers[fn] = nil
            return remove(w)
        end
        return remove(fn)
    end
    state.hooked = true
end

local function reportMissing()
    if state.found or state.reported then
        return
    end
    state.reported = true
    Core.logLn("compat: Whennyago Initiative is active but never registered the minute handler this patch " ..
                   "replaces. Nothing to patch; it has probably been fixed or rewritten upstream.")
end

state.active = isActive()
if state.active then
    install()
    Events.OnGameStart.Add(reportMissing)
    Events.OnServerStarted.Add(reportMissing)
end

return state
