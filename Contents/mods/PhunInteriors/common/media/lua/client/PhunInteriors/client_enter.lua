if isServer() then
    return
end
require "PhunInteriors/client_main"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Getting in takes time and can be interrupted, so the interior is not an
-- escape hatch you can reach mid chase. The server still re-checks everything
-- when the action completes; this is the felt cost, not the enforcement.
-- ---------------------------------------------------------------------------

PhunInteriorsEnterAction = ISBaseTimedAction:derive("PhunInteriorsEnterAction")

function PhunInteriorsEnterAction:isValid()
    return self.vehicle ~= nil and self.character:getVehicle() == nil
end

function PhunInteriorsEnterAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function PhunInteriorsEnterAction:update()
    self.character:faceThisObject(self.vehicle)
end

function PhunInteriorsEnterAction:start()
    self:setActionAnim("Loot")
end

function PhunInteriorsEnterAction:stop()
    ISBaseTimedAction.stop(self)
end

function PhunInteriorsEnterAction:perform()
    Client.requestEnter(self.vehicle)
    ISBaseTimedAction.perform(self)
end

function PhunInteriorsEnterAction:new(character, vehicle)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.vehicle = vehicle
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true

    local seconds = tonumber(Core.settings.EntryDelay) or 0
    -- maxTime is in ticks; roughly 60 per second at normal speed
    o.maxTime = seconds > 0 and (seconds * 60) or 1
    -- Vanilla honours the TimedActionInstant admin power everywhere; without
    -- this the entry delay ignores it, which makes testing painful.
    if character:isTimedActionInstant() then
        o.maxTime = 1
    end
    return o
end

--- Queue the walk-to plus the entry action.
function Client.beginEnter(vehicle)
    local player = getPlayer()
    if not player or not vehicle then
        return
    end
    if player:getVehicle() then
        player:getVehicle():exit(player)
    end
    ISTimedActionQueue.add(PhunInteriorsEnterAction:new(player, vehicle))
end
