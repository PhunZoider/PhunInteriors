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
    -- Which door we are stood at. Captured here rather than in beginEnter:
    -- by now any ISExitVehicle has run and the character is standing where
    -- they will actually be, so this is the door to put them back at. Works
    -- out the same for a seated player, who is stood at their own door.
    local standSeat = Client.nearestDoor(self.vehicle, self.character)
    Client.requestEnter(self.vehicle, self.seat, standSeat)
    ISBaseTimedAction.perform(self)
end

function PhunInteriorsEnterAction:new(character, vehicle, seat)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.vehicle = vehicle
    o.seat = seat or -1
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
    -- Capture the seat *here*, before anything leaves it. Our own isValid
    -- refuses to run until the character is out of the vehicle, so by the
    -- time the request reaches the server getSeat already returns -1 and the
    -- seat is lost. This is the only moment it can be read.
    local seat = -1
    local current = player:getVehicle()
    if current then
        if current == vehicle then
            seat = vehicle:getSeat(player)
        end
        -- Vanilla only ever leaves a seat through ISExitVehicle. Calling
        -- exit() straight from a menu skips the animation and the seat
        -- bookkeeping, so queue the vanilla action ahead of ours and let the
        -- queue sequence them.
        ISTimedActionQueue.add(ISExitVehicle:new(player))
    end
    ISTimedActionQueue.add(PhunInteriorsEnterAction:new(player, vehicle, seat))
end
