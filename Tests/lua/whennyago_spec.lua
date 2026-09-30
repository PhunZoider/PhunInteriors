-- The Whennyago Initiative compat patch: that it replaces the right handler,
-- drives the right parts on the right side, leaves the engine's work to the
-- engine, and hands back to Whennyago's own handler whenever something it
-- depends on stops holding.
--
-- What this CANNOT see is whether the engine really leaves a parked vehicle's
-- parts alone, or whether the Set iterator behaves on a dedicated server. Both
-- come from the bytecode and need one in game check each; see the file header.

local root = os.getenv("PI_ROOT") or "."
local stubs = dofile(root .. "/Tests/lua/stubs.lua")
local r = stubs.reporter()
local check = r.check

local SOURCE = "C:\\Users\\x\\Zomboid\\mods\\Whennyago_Initiative\\42\\media\\lua\\server\\" ..
                   "WhennyagoInitiative_VehicleUse.lua"

local function fakePart(id, spec)
    local p = {lastUpdated = 0}
    function p:getLuaFunction(k)
        if k ~= "update" then return nil end
        if spec.hook ~= nil then return spec.hook or nil end
        return "WhennyagoInitiative.Update." .. id
    end
    function p:getInventoryItem() return spec.installed ~= false and {} or nil end
    function p:setLastUpdated(t) self.lastUpdated = t end
    return p
end

local function fakeVehicle(name, spec)
    spec = spec or {}
    local parts = {}
    if spec.parts ~= false then
        for _, id in ipairs({"RoofSolarUpgrade", "RearGeneratorBoxUpgrade"}) do
            parts[id] = fakePart(id, spec[id] or {})
        end
    end
    local v = {parts = parts}
    function v:getScript() return {getName = function() return name end} end
    function v:getPartById(id) return parts[id] end
    function v:needPartsUpdate() return spec.engine == true end
    return v
end

-- One world per scenario: fresh stubs, fresh Core, fresh patch state.
local function boot(opts)
    opts = opts or {}
    stubs.install(root)
    local ev = Events.EveryOneMinute
    ev.Remove = function(fn)
        for i, h in ipairs(ev.fns) do
            if h == fn then table.remove(ev.fns, i) return end
        end
    end
    local files, lines = {}, {}
    function getFilenameOfClosure(fn) return files[fn] end
    function getFirstLineOfClosure(fn) return lines[fn] end
    function getActivatedMods()
        return {contains = function(_, id) return not opts.inactive and id == "WhennyagoInitiative" end}
    end
    function isClient() return opts.client == true end
    stubs.worldAge = 100

    local w = {logs = {}, calls = {solar = 0, box = 0, original = 0}, vehicles = opts.vehicles or {}}
    function getCell()
        return {
            getVehicles = function()
                return {
                    iterator = function()
                        if opts.brokenIterator then error("no iterator") end
                        local i = 0
                        return {
                            hasNext = function() return i < #w.vehicles end,
                            next = function() i = i + 1; return w.vehicles[i] end
                        }
                    end
                }
            end
        }
    end

    require "PhunInteriors/core"
    w.Core = PhunInteriors
    w.Core.logLn = function(s) table.insert(w.logs, s) end
    w.Core.debugLn = function() end
    w.state = require "PhunInteriors/compat_whennyago"

    WhennyagoInitiative = {Update = {
        RoofSolarUpgrade = function(_, _, m) w.calls.solar = w.calls.solar + m end,
        RearGeneratorBoxUpgrade = function(_, _, m) w.calls.box = w.calls.box + m end
    }}
    w.original = function() w.calls.original = w.calls.original + 1 end
    files[w.original] = SOURCE
    lines[w.original] = opts.line or 648
    w.other = function() end
    files[w.other] = "C:\\somewhere\\else.lua"

    if not opts.unregistered then
        ev.Add(w.original)
    end
    ev.Add(w.other)
    w.fns = ev.fns

    function w.minute()
        for _, fn in ipairs(ev.fns) do fn() end
    end
    function w.logged(text)
        for _, l in ipairs(w.logs) do
            if l:find(text, 1, true) then return true end
        end
        return false
    end
    return w
end

-- ---------------------------------------------------------------------------
-- Replacement, in single player.
-- ---------------------------------------------------------------------------
do
    local rv = fakeVehicle("WhennyagoInitiative")
    local car = fakeVehicle("CarNormal")
    local w = boot({vehicles = {car, rv}})
    check("its handler is replaced", w.fns[1] ~= w.original, true)
    check("anybody else's is not", w.fns[2], w.other)
    check("it was found", w.state.found, true)
    check("and said so", w.logged("replacing Whennyago"), true)
    w.minute()
    check("solar driven once", w.calls.solar, 1)
    check("generator box driven once", w.calls.box, 1)
    check("its own handler did not run", w.calls.original, 0)
    check("two parts counted", w.state.driven, 2)
    check("solar lastUpdated moved on", rv.parts.RoofSolarUpgrade.lastUpdated, 100)
    check("box lastUpdated moved on", rv.parts.RearGeneratorBoxUpgrade.lastUpdated, 100)
    check("another mod's car untouched", car.parts.RoofSolarUpgrade.lastUpdated, 0)
    check("nothing stood down", w.state.standDown, nil)
end

do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiative", {engine = true})}})
    w.minute()
    check("engine updating: left to the engine", w.calls.solar + w.calls.box, 0)
    check("engine updating: still no fallback", w.calls.original, 0)
end

do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiativeSmashedLeft", {
        RoofSolarUpgrade = {installed = false}})}})
    w.minute()
    check("a variant counts, an empty slot does not", w.calls.solar .. "/" .. w.calls.box, "0/1")
end

do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiativeBurnt", {parts = false})}})
    w.minute()
    check("a shell without the parts is not a contradiction", w.state.standDown, nil)
end

-- ---------------------------------------------------------------------------
-- Multiplayer client: never drives, but still checks the wiring.
-- ---------------------------------------------------------------------------
do
    local w = boot({client = true, vehicles = {fakeVehicle("WhennyagoInitiative")}})
    w.minute()
    check("client: nothing driven", w.calls.solar + w.calls.box, 0)
    check("client: its handler does not run either", w.calls.original, 0)
end

do
    local w = boot({client = true, vehicles = {fakeVehicle("WhennyagoInitiative", {
        RoofSolarUpgrade = {hook = "WhennyagoInitiative.Update.SolarV2"}})}})
    w.minute()
    check("client: rewired hook stands down", w.state.standDown ~= nil, true)
    check("client: and hands back that minute", w.calls.original, 1)
end

-- ---------------------------------------------------------------------------
-- Standing down.
-- ---------------------------------------------------------------------------
do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiative", {
        RearGeneratorBoxUpgrade = {hook = false}})}})
    w.minute()
    check("hook removed: stands down", w.state.standDown ~= nil, true)
    check("hook removed: its handler runs", w.calls.original, 1)
    w.minute()
    check("and keeps running", w.calls.original, 2)
    check("and says why", w.logged("RearGeneratorBoxUpgrade update hook is nil"), true)
end

do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiative")}})
    WhennyagoInitiative.Update.RoofSolarUpgrade = nil
    w.minute()
    check("power function gone: stands down", w.state.standDown ~= nil, true)
    check("power function gone: hands back", w.calls.original, 1)
end

do
    local w = boot({brokenIterator = true, vehicles = {fakeVehicle("WhennyagoInitiative")}})
    w.minute()
    check("a failing pass stands down", w.logged("replacement pass failed"), true)
    check("a failing pass hands back", w.calls.original, 1)
end

do
    local w = boot({vehicles = {fakeVehicle("WhennyagoInitiative")}})
    w.Core.settings.WhennyagoPatch = false
    w.minute()
    check("option off: shipped behaviour", w.calls.original, 1)
    check("option off: nothing of ours", w.calls.solar + w.calls.box, 0)
    w.Core.settings.WhennyagoPatch = true
    w.minute()
    check("option back on: ours again", w.calls.solar, 1)
end

-- ---------------------------------------------------------------------------
-- Registration.
-- ---------------------------------------------------------------------------
do
    local w = boot()
    Events.EveryOneMinute.Remove(w.original)
    check("Remove(original) takes the replacement", #w.fns == 1 and w.fns[1] == w.other, true)
end

do
    local w = boot({inactive = true})
    check("not installed: not hooked", w.state.hooked, false)
    check("not installed: handler untouched", w.fns[1], w.original)
end

do
    local w = boot({line = 702})
    check("a moved handler is still patched", w.fns[1] ~= w.original, true)
    check("a moved handler is reported", w.logged("moved to line 702"), true)
end

do
    local w = boot({unregistered = true})
    triggerEvent("OnGameStart")
    triggerEvent("OnServerStarted")
    check("never registered: reported", w.logged("never registered"), true)
    local n = 0
    for _, l in ipairs(w.logs) do if l:find("never registered", 1, true) then n = n + 1 end end
    check("never registered: reported once", n, 1)
end

os.exit(r.finish("whennyago") == 0 and 0 or 1)
