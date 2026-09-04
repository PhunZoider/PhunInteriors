if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Slots = require "PhunInteriors/slots"
local Scrub = require "PhunInteriors/scrub"
local Manifest = require "PhunInteriors/manifest"
local Transit = require "PhunInteriors/transit"
local Admin = {}
Core.modules.admin = Admin

-- ---------------------------------------------------------------------------
-- Admin actions.
--
-- PhunServer2 is a hook, never a dependency. When it is loaded these register
-- as chat commands; when it is not, they are still reachable through the
-- client command path. This mod has no hard dependencies.
-- ---------------------------------------------------------------------------

local actions = {}

actions.list = function()
    local summary = Slots.summary()
    local lines = {}
    for _, set in ipairs(summary.sets) do
        table.insert(lines, string.format("%s: %d/%d leased (%s)",
            set.id, set.used, set.total, set.source))
    end
    table.insert(lines, string.format("quarantine: %d slot(s) awaiting scrub", summary.quarantine))
    return lines
end

actions.free = function(args)
    local vehicleId = args.vehicleId
    if not vehicleId then
        return {"free needs a vehicleId"}
    end
    if Slots.release(vehicleId, "admin") then
        return {"released the room leased to " .. tostring(vehicleId)}
    end
    return {"no room is leased to " .. tostring(vehicleId)}
end

actions.scrub = function(args)
    if args.roomSet and args.index then
        local ok, reason = Scrub.slot(args.roomSet, tonumber(args.index))
        return {ok and "scrubbed" or ("could not scrub: " .. tostring(reason))}
    end
    local done = Scrub.processQueue(10)
    return {"scrubbed " .. done .. " quarantined slot(s)"}
end

actions.evict = function(args)
    local username = args.username
    if not username then
        return {"evict needs a username"}
    end
    local player = Core.tools.getPlayerByUsername(username)
    if not player then
        return {username .. " is not online"}
    end
    if Transit.leave(player, "admin") then
        return {"evicted " .. username}
    end
    return {username .. " is not inside a room"}
end

-- What every captured blueprint weighs. This is the measurement the design
-- note asks for: the estimates there were derived from room dimensions, and
-- nothing had ever been captured to check them against.
actions.manifests = function()
    return Manifest.report()
end

-- Rescan one slot you are standing in. Targets a slot rather than a room set
-- because there is no golden slot any more, and a blueprint is only ever as
-- good as the room it was read from.
actions.remanifest = function(args)
    local roomSet = args.roomSet
    local index = tonumber(args.index)
    if not roomSet or not index then
        return {"remanifest needs a roomSet and an index"}
    end
    if Core.shippedBlueprint(roomSet, index) then
        return {roomSet .. "#" .. index .. " ships a blueprint; rescanning would be ignored"}
    end
    Manifest.forgetSlot(roomSet, index)
    local captured, reason = Manifest.captureSlot(roomSet, index, true)
    if captured then
        return {"recaptured " .. roomSet .. "#" .. index .. ": " .. captured.objectCount .. " objects"}
    end
    return {"could not capture " .. roomSet .. "#" .. index .. ": " .. tostring(reason)}
end

function Admin.run(action, args)
    local handler = actions[action]
    if not handler then
        local names = {}
        for name in pairs(actions) do
            table.insert(names, name)
        end
        table.sort(names)
        return {"unknown action. try: " .. table.concat(names, ", ")}
    end
    local ok, result = pcall(handler, args)
    if not ok then
        Core.logLn("admin action " .. tostring(action) .. " failed: " .. tostring(result))
        return {"that failed, check the server log"}
    end
    return result
end

--- Soft hook into PhunServer2 if it happens to be loaded.
function Admin.registerChatCommands()
    if not PhunServer2 or not PhunServer2.registerCommand then
        Core.debugLn("PhunServer2 not present, skipping chat command registration")
        return false
    end

    PhunServer2.registerCommand("interiors", {
        adminOnly = true,
        help = function()
            return getText("IGUI_PhunInteriors_AdminUsage")
        end,
        action = function(player, arguments)
            local parts = {}
            for word in string.gmatch(arguments or "", "%S+") do
                table.insert(parts, word)
            end
            local result = Admin.run(parts[1] or "list", {
                vehicleId = parts[2],
                roomSet = parts[2],
                index = parts[3],
                username = parts[2]
            })
            for _, line in ipairs(result) do
                Core.logLn(line)
            end
            return result
        end
    })

    Core.logLn("registered /interiors with PhunServer2")
    return true
end

return Admin
