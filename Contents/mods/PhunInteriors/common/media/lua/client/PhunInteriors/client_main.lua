if isServer() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The client only moves the player and draws menus. Every decision about
-- whether a move is allowed is made server side.
-- ---------------------------------------------------------------------------

Core.client = Core.client or {}
local Client = Core.client

--- True while this client believes it is inside one of our rooms. Used only
--- for menu state; the server is the authority.
Client.inside = false

-- ---------------------------------------------------------------------------
-- Teleporting across the map.
--
-- teleportTo moves the player immediately, but the destination chunk is not
-- loaded yet and the engine restores anyone standing on a square that does not
-- exist. A single call therefore looks like it worked and then silently undoes
-- itself a frame later.
--
-- So we re-assert the position every tick until the destination square is
-- actually there. Re-teleporting also keeps the chunk map centred on the
-- destination, which is what makes it stream in. This matters in both
-- directions: coming back out, the vehicle's chunk has been unloaded all the
-- time the player was inside.
-- ---------------------------------------------------------------------------

local HOLD_TICKS = 180

local pending = nil

local function holdTeleport()
    local player = getPlayer()
    if not pending or not player then
        pending = nil
        Events.OnTick.Remove(holdTeleport)
        return
    end

    pending.ticks = pending.ticks + 1

    local square = getCell() and getCell():getGridSquare(pending.x, pending.y, pending.z)
    local arrived = square ~= nil
        and math.floor(player:getX()) == pending.x
        and math.floor(player:getY()) == pending.y

    if arrived then
        Core.debugLn(string.format("teleport: arrived at %s,%s,%s after %d tick(s)",
            tostring(pending.x), tostring(pending.y), tostring(pending.z), pending.ticks))
        pending = nil
        Events.OnTick.Remove(holdTeleport)
        return
    end

    if pending.ticks >= HOLD_TICKS then
        Core.logLn(string.format(
            "teleport: gave up after %d ticks; %s,%s,%s never loaded (square is %s, player at %s,%s)",
            pending.ticks, tostring(pending.x), tostring(pending.y), tostring(pending.z),
            square and "there" or "still nil",
            tostring(player:getX()), tostring(player:getY())))
        pending = nil
        Events.OnTick.Remove(holdTeleport)
        return
    end

    player:teleportTo(pending.x + 0.5, pending.y + 0.5, pending.z)
end

function Client.teleport(data)
    local player = getPlayer()
    if not player or not data then
        return
    end

    -- Out of the seat first. player:getVehicle() is the test; BaseVehicle has
    -- no isInVehicle. Nil on the way back out of a room, so this no-ops there.
    local vehicle = player:getVehicle()
    if vehicle then
        vehicle:exit(player)
        triggerEvent("OnExitVehicle", player)
    end

    Core.debugLn(string.format("teleport: asked for %s,%s,%s; player at %s,%s,%s",
        tostring(data.x), tostring(data.y), tostring(data.z),
        tostring(player:getX()), tostring(player:getY()), tostring(player:getZ())))

    player:teleportTo(data.x + 0.5, data.y + 0.5, data.z)

    -- Hold it there until the chunk exists. A fresh request replaces any
    -- in-flight one rather than stacking a second handler.
    local wasPending = pending ~= nil
    pending = {
        x = math.floor(data.x),
        y = math.floor(data.y),
        z = math.floor(data.z),
        ticks = 0
    }
    if not wasPending then
        Events.OnTick.Add(holdTeleport)
    end

    Client.inside = data.inside and true or false
end

function Client.notify(data)
    if not data or not data.text then
        return
    end
    local player = getPlayer()
    if not player then
        return
    end
    local text = getText(data.text)
    if data.warning then
        player:setHaloNote(text, 255, 180, 60, 300)
    else
        player:setHaloNote(text, 200, 220, 200, 300)
    end
end

--- Ask to go in. The server decides.
function Client.requestEnter(vehicle)
    if not vehicle then
        return
    end
    Core.dispatch(Core.commands.enter, {
        x = vehicle:getX(),
        y = vehicle:getY(),
        z = vehicle:getZ()
    })
end

--- Ask to come out. Normally the exit tile does this without being asked, but
--- the context menu is a discoverable affordance and a safety net.
function Client.requestLeave()
    Core.dispatch(Core.commands.leave, {reason = "exit"})
end

return Client
