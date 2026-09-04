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
    if not Core.occupants[Core.playerKey(player)] then
        Transit.recover(player)
    end
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

Commands[Core.commands.leave] = function(player, args)
    Transit.leave(player, (args and args.reason) or "exit")
end

Commands[Core.commands.admin] = function(player, args)
    if not Core.tools.isAdmin(player) then
        Core.logLn("rejected an admin command from " .. tostring(Core.playerKey(player)))
        return
    end

    local admin = require "PhunInteriors/admin"
    local action = args and args.action
    local result = admin.run(action, args or {})

    Core.respond(player, Core.commands.adminResult, {
        action = action,
        result = result
    })
end

return Commands
