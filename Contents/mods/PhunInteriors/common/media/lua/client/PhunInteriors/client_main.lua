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
local SEAT_TICKS = 120

local pending = nil
local holdTeleport

local function stopHolding()
    pending = nil
    Events.OnTick.Remove(holdTeleport)
end

--- The seat we came from if it is still free, otherwise the best one going.
local function resolveSeat(vehicle, wanted, player)
    if wanted and wanted >= 0 and not vehicle:isSeatOccupied(wanted) then
        return wanted
    end
    local best = vehicle:getBestSeat(player)
    if best and best >= 0 and not vehicle:isSeatOccupied(best) then
        return best
    end
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if not vehicle:isSeatOccupied(seat) then
            return seat
        end
    end
    return nil
end

-- Second phase, once the position has landed.
--
-- The server cannot do either of these things. While the player is inside, the
-- vehicle's chunk is unloaded, so from the server an unloaded vehicle and a
-- destroyed one look identical -- which is why it used to warn "your vehicle
-- is gone" on every single normal exit. And vanilla only ever puts a character
-- into a seat from a client timed action.
-- Find the vehicle by the identity that actually survives.
--
-- Not getVehicleById. BaseVehicle:getId() is assigned when a vehicle enters
-- the world, and the vehicle unloads while its owner is off in a room, so it
-- comes back carrying a *different* id and the handle we captured on the way
-- in is dead. Confirmed from the logs: the van was plainly there and the
-- lookup returned nil on every single exit.
--
-- Our own UUID lives in the vehicle modData and is written into the save, so
-- it does survive. Sweep the squares around where we landed and match on it.
local SEARCH_RADIUS = 3

local function findVehicle()
    return Core.vehicleNear(pending.x, pending.y, pending.z, pending.vehicleId, SEARCH_RADIUS)
end

-- Where a character stands to use a seat, in world coordinates. Vanilla
-- computes it exactly this way in ISEnterVehicle and ISVehicleMenu, and
-- reuses one Vector3f rather than allocating per call.
local WORLD_POS = Vector3f.new()

local function outsidePosition(vehicle, seat)
    local position = vehicle:getPassengerPosition(seat, "outside")
    if not position then
        return nil
    end
    local worldPos = vehicle:getWorldPos(position:getOffset(), WORLD_POS)
    if not worldPos then
        return nil
    end
    return worldPos:x(), worldPos:y()
end

--- The seat whose door this character is standing nearest, or nil.
--
-- Deliberately not getBestSeat. That returns -1 here, confirmed from the
-- logs: every single capture recorded "door -1", seated entries included, so
-- the door was never actually remembered. Vanilla picks a seat the same way
-- this does, by measuring to each seat's outside position (ISVehicleMenu's
-- distanceToPassengerPosition), which is the same call our own landing code
-- already relies on.
function Client.nearestDoor(vehicle, character)
    local best, bestDistance = nil, nil
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        local x, y = outsidePosition(vehicle, seat)
        if x then
            local dx, dy = x - character:getX(), y - character:getY()
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = seat, distance
            end
        end
    end
    return best
end

local function rejoinVehicle(player)
    local vehicle = findVehicle()

    if not vehicle then
        pending.seatTicks = pending.seatTicks + 1
        if pending.seatTicks >= SEAT_TICKS then
            -- Chunk is loaded and the vehicle is not in it. Now the warning is
            -- true, which it was not when the server sent it.
            Core.debugLn("rejoin: no vehicle matching " .. tostring(pending.vehicleId) ..
                " within " .. SEARCH_RADIUS .. " squares of " .. pending.x .. "," .. pending.y ..
                " after " .. pending.seatTicks .. " ticks")
            Client.notify({text = "IGUI_PhunInteriors_VehicleGone", warning = true})
            stopHolding()
        end
        return
    end

    -- Only re-seat someone who was seated on the way in. A player who walked
    -- up to the van on foot should come back out on foot.
    local seat = nil
    if pending.seat and pending.seat >= 0 then
        seat = resolveSeat(vehicle, pending.seat, player)
        if not seat then
            Core.debugLn("rejoin: every seat is occupied, staying outside")
        end
    end

    -- Land beside the vehicle rather than in the middle of its model. The
    -- server can only ever send us the vehicle position, which is its centre.
    --
    -- This is also what makes re-seating work at all: ISEnterVehicle:start()
    -- silently returns without entering when the character is more than two
    -- tiles from this exact position, and the centre of a van is further than
    -- that. isValid then drops the action, so it failed by leaving the player
    -- standing there. Confirmed from the logs, which recorded "seat 0
    -- requested, taking 0" on an exit that put the player outside.
    -- The seat we are retaking, else the door we came in by, else whatever is
    -- nearest. Without the middle one every on-foot exit uses the same door,
    -- because getBestSeat is measured from the vehicle centre we land on.
    local standAt = seat or pending.standSeat
    if not standAt or standAt < 0 then
        standAt = Client.nearestDoor(vehicle, player)
    end
    if not standAt or standAt < 0 then
        standAt = 0
    end
    local x, y = outsidePosition(vehicle, standAt)
    if x then
        player:teleportTo(x, y, player:getZ())
    end

    if seat then
        Core.debugLn("rejoin: seat " .. tostring(pending.seat) .. " requested, taking " .. tostring(seat))
        ISTimedActionQueue.add(ISEnterVehicle:new(player, vehicle, seat))
    end

    stopHolding()
end

function holdTeleport()
    local player = getPlayer()
    if not pending or not player then
        stopHolding()
        return
    end

    if pending.arrived then
        rejoinVehicle(player)
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
        -- Coming back out there is a second phase: wait for the vehicle to
        -- appear in the freshly streamed chunk, then get back in it.
        if pending.vehicleHandle then
            pending.arrived = true
            pending.seatTicks = 0
            return
        end
        stopHolding()
        return
    end

    if pending.ticks >= HOLD_TICKS then
        Core.logLn(string.format(
            "teleport: gave up after %d ticks; %s,%s,%s never loaded (square is %s, player at %s,%s)",
            pending.ticks, tostring(pending.x), tostring(pending.y), tostring(pending.z),
            square and "there" or "still nil",
            tostring(player:getX()), tostring(player:getY())))
        stopHolding()
        return
    end

    player:teleportTo(pending.x + 0.5, pending.y + 0.5, pending.z)
end

function Client.teleport(data)
    local player = getPlayer()
    if not player or not data then
        return
    end

    -- Put away anything that watches where the player is standing.
    --
    -- A teleport leaves the player with no square at all until the
    -- destination chunk streams in, and vanilla UI does not expect that.
    -- ISBuildWindow:update calls originalSquare:DistToProper(player:getSquare())
    -- to decide whether to auto-close, which throws a NullPointerException on
    -- the nil square and then a cascade of __le failures every frame after.
    -- Vanilla has the same instinct in ISEnterVehicle:start, which clears the
    -- drag cursor and hides the context menu before moving anybody.
    local playerNum = player:getPlayerNum()
    if getCell() then
        getCell():setDrag(nil, playerNum)
    end
    local contextMenu = getPlayerContextMenu(playerNum)
    if contextMenu and contextMenu:isAnyVisible() then
        contextMenu:hideAndChildren()
    end
    if ISBuildWindow and ISBuildWindow.instance then
        -- pcall because this reaches into vanilla UI state we do not own
        pcall(function() ISBuildWindow.instance:close() end)
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
        ticks = 0,
        arrived = false,
        -- Only set on the way out; nil going in, which skips the second phase.
        vehicleHandle = data.vehicleHandle,
        vehicleId = data.vehicleId,
        seat = data.seat,
        standSeat = data.standSeat
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
function Client.requestEnter(vehicle, seat, standSeat)
    if not vehicle then
        return
    end
    Core.dispatch(Core.commands.enter, {
        x = vehicle:getX(),
        y = vehicle:getY(),
        z = vehicle:getZ(),
        -- Read before the character left the seat; see client_enter.
        seat = seat,
        -- The door they are stood at, so they come back out at the same one.
        standSeat = standSeat
    })
end

--- Ask to come out. Normally the exit tile does this without being asked, but
--- the context menu is a discoverable affordance and a safety net.
function Client.requestLeave()
    Core.dispatch(Core.commands.leave, {reason = "exit"})
end


-- ---------------------------------------------------------------------------
-- Admin entry point.
--
-- admin.lua's handler and the adminResult printer both existed, but nothing
-- ever dispatched between them, so with PhunServer2 absent -- which is the
-- normal case, since it is a soft hook and never a dependency -- the whole
-- admin surface was unreachable.
--
-- This is the single client side caller. Type it into the debug console:
--
--     PhunInteriors.admin("list")
--     PhunInteriors.admin("remanifest", {roomSet = "phun.van", index = 4})
--     PhunInteriors.admin("scrub", {roomSet = "phun.van", index = 3})
--     PhunInteriors.admin("free", {vehicleId = "..."})
--     PhunInteriors.admin("age", {vehicleId = "...", days = 99})
--     PhunInteriors.admin("sweepleases")
--     PhunInteriors.admin("reload")   -- after changing a sandbox option
--     PhunInteriors.admin("weight")
--     PhunInteriors.admin("evict", {username = "..."})
--
-- Results come back through Core.commands.adminResult and print to the log,
-- which is also where they land in multiplayer. The server re-checks admin
-- rights in server_commands, so this is an entry point, not a bypass.
--
-- Deliberately one function taking an action name rather than a function per
-- action: it is the same shape PhunServer2's chat command drives, and the same
-- shape an admin UI would drive later, so none of this gets rewritten.
-- ---------------------------------------------------------------------------
--- Build a room set from where you are standing and emit the lua for it.
--
--     PhunInteriors.author("begin", {id = "yourmod.van"})
--     PhunInteriors.author("corner")   -- twice, opposite corners of room 1
--     PhunInteriors.author("spawn")    -- standing on the spawn tile
--     PhunInteriors.author("exit")     -- standing on each exit tile
--     PhunInteriors.author("power")    -- standing on the generator square
--     PhunInteriors.author("strip", {count = 38, pitchX = 60})
--     PhunInteriors.author("scripts", {scripts = "Base.Van, Base.VanSeats", match = "Van"})
--     PhunInteriors.author("sweep")    -- repeat as you walk the strip
--     PhunInteriors.author("emit")
--
-- Same dispatcher shape as admin, for the same reason: a panel later is a
-- view over these calls rather than a rewrite.
--- Everything the caller passed, minus anything that would not survive the
--- trip to a dedicated server.
--
-- These used to name each field they forwarded, which meant every new action
-- silently dropped any argument nobody remembered to add to the list. It cost
-- a debugging session: admin("age", {days = 13}) never sent days at all, so
-- the server fell through to its default and reported a number the caller had
-- never asked for.
local function payload(action, args, fallback)
    local out = {action = action or fallback}
    for key, value in pairs(args or {}) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            out[key] = value
        else
            Core.logLn("dropping '" .. tostring(key) .. "' from the command: a " ..
                kind .. " cannot be sent to the server")
        end
    end
    return out
end

function Core.author(action, args)
    Core.dispatch(Core.commands.author, payload(action, args, "status"))
    return "sent; results are printed to the log"
end

function Core.admin(action, args)
    Core.dispatch(Core.commands.admin, payload(action, args, "list"))
    return "sent; results are printed to the log"
end

return Client
