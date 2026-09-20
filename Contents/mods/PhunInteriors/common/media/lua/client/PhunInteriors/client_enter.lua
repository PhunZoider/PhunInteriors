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

--- Out of any vehicle, or already aboard the one we are climbing into.
--
-- It used to demand getVehicle() == nil, which meant a seated player could
-- only ever get here after ISExitVehicle had run. That action's isValid is
-- vehicle:isStopped(), so in a *moving* vehicle it never ran, this never
-- became valid, and the queue dropped both -- silently. Entering the back of a
-- van somebody else was towing was impossible, and looked like a broken menu.
function PhunInteriorsEnterAction:isValid()
    if not self.vehicle then
        return false
    end
    local current = self.character:getVehicle()
    return current == nil or current == self.vehicle
end

--- Seated players skip all the facing work: they cannot turn, so waiting on
--- shouldBeTurning would never finish.
function PhunInteriorsEnterAction:isAboard()
    return self.character:getVehicle() ~= nil
end

function PhunInteriorsEnterAction:waitToStart()
    if self:isAboard() then
        return false
    end
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function PhunInteriorsEnterAction:update()
    if self:isAboard() then
        return
    end
    self.character:faceThisObject(self.vehicle)
end

function PhunInteriorsEnterAction:start()
    -- Loot is a standing animation and there is no seated equivalent worth
    -- borrowing, so somebody moving through from a seat just takes the time.
    if not self:isAboard() then
        self:setActionAnim("Loot")
    end
end

function PhunInteriorsEnterAction:stop()
    ISBaseTimedAction.stop(self)
end

function PhunInteriorsEnterAction:perform()
    -- Which door to put them back at on the way out. Somebody still in a seat
    -- comes back to that seat's door; for anyone on foot this is measured now
    -- rather than in beginEnter, because by now any ISExitVehicle has run and
    -- they are standing where they will actually be.
    local standSeat = self.seat
    if not standSeat or standSeat < 0 then
        standSeat = Client.nearestDoor(self.vehicle, self.character)
    end
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

    -- Refuse here as well as server side, so a refusal costs nothing instead
    -- of arriving after a fifteen second action. Same function on both sides;
    -- the server is still the authority and re-checks it in Transit.canEnter.
    local allowed, why = Core.vehicleMotionAllows(vehicle, player)
    if not allowed then
        Client.notify({text = why, warning = true})
        return
    end

    -- Capture the seat *here*, before anything leaves it. By the time the
    -- request reaches the server getSeat already returns -1, so this is the
    -- only moment it can be read.
    local seat = -1
    local current = player:getVehicle()

    if current == vehicle then
        -- Already aboard, so there is nothing to climb out of: moving from a
        -- seat into the interior is an internal move, the mirror of coming
        -- back out into a free seat. Client.teleport calls vehicle:exit() when
        -- the server says go, which is what actually vacates the seat.
        --
        -- Queueing ISExitVehicle here instead is what made entering a moving
        -- vehicle impossible -- its isValid is vehicle:isStopped().
        seat = vehicle:getSeat(player)
    elseif current then
        -- A different vehicle, which does have to be left properly. Vanilla
        -- only ever leaves a seat through ISExitVehicle; calling exit() from a
        -- menu skips the animation and the seat bookkeeping.
        ISTimedActionQueue.add(ISExitVehicle:new(player))
    end

    ISTimedActionQueue.add(PhunInteriorsEnterAction:new(player, vehicle, seat))
end
