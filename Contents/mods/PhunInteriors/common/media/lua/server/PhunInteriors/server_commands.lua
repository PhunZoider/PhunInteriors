if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Transit = require "PhunInteriors/transit"
local Commands = {}

--- Find the vehicle a client claims to be interacting with, without trusting
--- the client about which vehicle that is.
local function resolveVehicle(player, args)
    local vehicle = player:getVehicle() or player:getUseableVehicle()
    if vehicle then
        return vehicle
    end

    if not args or not args.x then
        return nil
    end

    -- The client sent a position. Accept it only if it is close enough to the
    -- player to be plausible.
    local dx, dy = args.x - player:getX(), args.y - player:getY()
    if (dx * dx + dy * dy) > 100 then
        Core.debugLn("rejected an enter request for a vehicle too far from the player")
        return nil
    end

    local square = getCell():getGridSquare(args.x, args.y, args.z or 0)
    return square and square:getVehicleContainer() or nil
end

Commands[Core.commands.playerSetup] = function(player, args)
    -- A player who logs in already standing in a room needs their occupancy
    -- rebuilt before the leash sees them and ejects them.
    --
    -- And if there is no lease to rebuild it from, they are in a room that is
    -- nobody's -- reclaimed while they were away, or released out from under
    -- them. Recover cannot help with that; rescueStranded puts them back where
    -- they went in, which is the one thing still known about them.
    if not Core.occupants[Core.playerKey(player)] then
        if not Transit.recover(player) then
            Transit.rescueStranded(player)
        end
    end

    -- Then tell them, because the client has no other way to find out. It
    -- only learns it is inside from a teleport, and reconnecting is the one
    -- path into a room that does not involve one.
    Core.respond(player, Core.commands.state, {
        inside = Core.occupants[Core.playerKey(player)] ~= nil
    })
end

Commands[Core.commands.enter] = function(player, args)
    local vehicle = resolveVehicle(player, args)
    if not vehicle then
        Core.respond(player, Core.commands.notify, {
            text = "IGUI_PhunInteriors_NoVehicle",
            warning = true
        })
        return
    end
    Transit.enter(player, vehicle, args and args.seat, args and args.standSeat)
end

-- "Put me inside the thing standing here."
--
-- The message carries a square and nothing else, so there is no identity in it
-- to take on trust: the server reads the object off the square itself, exactly
-- as the vehicle path reads a vehicle off a position. The plausibility check is
-- the same too -- a client naming a square on the other side of the map is
-- either broken or lying, and neither is worth serving.
Commands[Core.commands.enterObject] = function(player, args)
    if not args or not args.x then
        return
    end

    local dx, dy = args.x - player:getX(), args.y - player:getY()
    if (dx * dx + dy * dy) > 100 then
        Core.debugLn("rejected an object entry for a square too far from the player")
        return
    end

    local object, anchor = Core.boundObjectAt(args.x, args.y, args.z or 0)
    if not object then
        Core.respond(player, Core.commands.notify, {
            text = "IGUI_PhunInteriors_NoVehicle",
            warning = true
        })
        return
    end

    Transit.enterObject(player, object, anchor)
end

Commands[Core.commands.leave] = function(player, args)
    -- No `via`. Asking to leave through the menu is not walking out of any
    -- particular side, so there is no edge to attribute it to and it lands
    -- beside the vehicle, which is what it always did.
    Transit.leave(player, (args and args.reason) or "menu")
end

-- "This vehicle just moved, go and look at it." Carries an id and no
-- coordinates, so there is nothing here worth validating: the id either
-- resolves to a loaded vehicle holding one of our leases or it does not, and
-- the position is read from the vehicle rather than from the message.
Commands[Core.commands.updatePosition] = function(player, args)
    Transit.notePosition(tonumber(args and args.id))
end

-- The player has landed back outside and is naming the vehicle they found.
-- Checked against the lease in Transit.arrived, never taken at face value.
Commands[Core.commands.arrived] = function(player, args)
    Transit.arrived(player, tonumber(args and args.id), args and args.seated)
end

-- The player has landed INSIDE a room. Only a flag: the leash still has to see
-- them inside the box itself before the grace ends, so a report that arrives
-- ahead of the position update, or one that is simply false, changes nothing.
Commands[Core.commands.landed] = function(player, args)
    local occupancy = Transit.occupancyOf(player)
    if occupancy then
        occupancy.landed = true
    end
end

-- An admin is about to remove a vehicle. Nothing is released on the strength of
-- this; the server watches the vehicle and acts only if it really goes.
Commands[Core.commands.vehicleRemoving] = function(player, args)
    require("PhunInteriors/removal").watch(player, tonumber(args and args.id))
end

-- Put a rain reservoir on the roof of the room the player is in. The message
-- names the kit and nothing else: the room comes off the occupancy, and the
-- kit is looked up in the player's own inventory, so there is nothing in it to
-- take on trust.
Commands[Core.commands.installReservoir] = function(player, args)
    require("PhunInteriors/rainwater").install(player, tonumber(args and args.id))
end

Commands[Core.commands.author] = function(player, args)
    if not Core.tools.isAdmin(player) then
        Core.logLn("rejected an author command from " .. tostring(Core.playerKey(player)))
        return
    end

    local author = require "PhunInteriors/author"
    local result = author.run(args and args.action, args or {})

    Core.respond(player, Core.commands.adminResult, {
        action = args and args.action,
        result = result
    })
end

Commands[Core.commands.admin] = function(player, args)
    if not Core.tools.isAdmin(player) then
        Core.logLn("rejected an admin command from " .. tostring(Core.playerKey(player)))
        return
    end

    local admin = require "PhunInteriors/admin"
    local action = args and args.action
    local result = admin.run(action, args or {}, player)

    Core.respond(player, Core.commands.adminResult, {
        action = action,
        result = result
    })
end

--- The same gate every admin command uses. The window is an entry point,
--- never a bypass: each of these is re-checked here whatever the client's UI
--- decided to show.
local function refuse(player, what)
    if Core.tools.isAdmin(player) then
        return false
    end
    Core.logLn("rejected " .. what .. " from " .. tostring(Core.playerKey(player)))
    return true
end

-- The admin room list: ask, and be sent the whole state back rather than a
-- diff of it. The window is only open while somebody is looking at it, so a
-- full refresh costs less than keeping two copies honest.
--
-- Rooms WITHOUT their slots. It used to carry every slot of every room, which
-- was 120 of them on a two room map and is 960 across 81 rooms now -- all but
-- one room's worth drawn by nothing until a row is selected.
Commands[Core.commands.rooms] = function(player, args)
    if refuse(player, "a room query") then
        return
    end

    local admin = require "PhunInteriors/admin"
    local state = admin.roomState(player)
    -- Bindings ride along with the list rather than having a fetch of their
    -- own. There are a few dozen of them, they are small, and the editor shows
    -- them beside the rooms -- so a second round trip would buy nothing but a
    -- window that can be half refreshed.
    state.bindings = admin.bindingState()
    Core.respond(player, Core.commands.roomsResult, state)
end

-- One room's slots, fetched when its row is selected.
Commands[Core.commands.roomSlots] = function(player, args)
    if refuse(player, "a slot query") then
        return
    end

    local admin = require "PhunInteriors/admin"
    Core.respond(player, Core.commands.roomSlotsResult,
        admin.roomDetail(player, args and args.room))
end

-- An edit. Routed through Admin.run rather than straight at the override layer
-- so that the console path and the window path are the same code -- including
-- the validation, which is the half that matters.
Commands[Core.commands.editRoom] = function(player, args)
    if refuse(player, "a room edit") then
        return
    end

    local admin = require "PhunInteriors/admin"
    local result = admin.run("editRoom", args or {}, player)
    Core.respond(player, Core.commands.adminResult, {
        action = "editRoom",
        result = result
    })
end

Commands[Core.commands.editBinding] = function(player, args)
    if refuse(player, "a binding edit") then
        return
    end

    local admin = require "PhunInteriors/admin"
    local result = admin.run("editBinding", args or {}, player)
    Core.respond(player, Core.commands.adminResult, {
        action = "editBinding",
        result = result
    })
end

return Commands
