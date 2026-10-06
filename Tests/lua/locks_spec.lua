-- Whether a vehicle's locks keep somebody out of its interior.
--
-- What this CANNOT see is whether the part, door and window calls answer the
-- way vanilla's own Lua reads them on a real vehicle. What it can see is the
-- rule: which ways in count, and the two cases where vanilla's own helper
-- would give the wrong answer here -- a doorless trailer, and the hood.

local root = os.getenv("PI_ROOT") or "."
local stubs = dofile(root .. "/Tests/lua/stubs.lua")
stubs.install(root)

require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function() end
Core.debugLn = function() end
Core.settings.EntryNeedsUnlocked = true

local r = stubs.reporter()
local check = r.check

-- A part is {id, door = {locked, open}, window = {open, destroyed}, missing}.
local function fakeVehicle(parts, opts)
    opts = opts or {}
    local v = {}
    function v:getPartCount() return #parts end
    function v:getPartByIndex(i)
        local p = parts[i + 1]
        if not p then
            return nil
        end
        return {
            getId = function() return p.id end,
            getInventoryItem = function() return not p.missing and {} or nil end,
            getDoor = function()
                return p.door and {
                    isLocked = function() return p.door.locked end,
                    isOpen = function() return p.door.open end
                } or nil
            end,
            getWindow = function()
                return p.window and {
                    isOpen = function() return p.window.open end,
                    isDestroyed = function() return p.window.destroyed end
                } or nil
            end
        }
    end
    function v:getKeyId() return 77 end
    function v:isKeyIsOnDoor() return opts.keyOnDoor == true end
    return v
end

local function person(keys, aboard)
    return {
        getVehicle = function() return aboard end,
        getInventory = function()
            return {haveThisKeyId = function(_, id) return keys and keys[id] == true end}
        end
    }
end

local function lockedCar(extra)
    local parts = {
        {id = "DoorFrontLeft", door = {locked = true}},
        {id = "DoorFrontRight", door = {locked = true}},
        {id = "TrunkDoor", door = {locked = true}},
        {id = "WindowFrontLeft", window = {}}
    }
    for _, p in ipairs(extra or {}) do
        table.insert(parts, p)
    end
    return parts
end

local stranger = person()

local ok, why = Core.vehicleLockAllows(fakeVehicle(lockedCar()), stranger)
check("a locked car keeps a stranger out", ok, false)
check("and says it is locked", why, "IGUI_PhunInteriors_VehicleLocked")

check("the key lets you in", Core.vehicleLockAllows(fakeVehicle(lockedCar()), person({[77] = true})), true)
check("the wrong key does not", (Core.vehicleLockAllows(fakeVehicle(lockedCar()), person({[5] = true}))), false)
check("the key in the door lets you in", Core.vehicleLockAllows(fakeVehicle(lockedCar(), {keyOnDoor = true}), stranger),
    true)

local car = fakeVehicle(lockedCar())
check("somebody aboard is never asked", Core.vehicleLockAllows(car, person(nil, car)), true)

local one = lockedCar()
one[3].door.locked = false
check("one unlocked door is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

one = lockedCar()
one[1].door.open = true
check("an open door is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

one = lockedCar()
one[2].missing = true
check("a missing door is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

one = lockedCar()
one[4].window.destroyed = true
check("a smashed window is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

one = lockedCar()
one[4].window.open = true
check("an open window is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

one = lockedCar()
one[4].missing = true
check("a missing window is a way in", Core.vehicleLockAllows(fakeVehicle(one), stranger), true)

check("an unlocked hood is not", (Core.vehicleLockAllows(fakeVehicle(lockedCar({
    {id = "EngineDoor", door = {locked = false, open = true}}
})), stranger)), false)

check("a trailer with no doors is never locked", Core.vehicleLockAllows(fakeVehicle({
    {id = "TrailerTrunk"}
}), stranger), true)

SandboxVars = {VehicleEasyUse = true}
check("VehicleEasyUse lets everybody in", Core.vehicleLockAllows(fakeVehicle(lockedCar()), stranger), true)
SandboxVars = nil

Core.settings.EntryNeedsUnlocked = false
check("with the setting off nothing is asked", Core.vehicleLockAllows(fakeVehicle(lockedCar()), stranger), true)

os.exit(r.finish("locks") == 0 and 0 or 1)
