if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Transit = require "PhunInteriors/transit"
local Manifest = require "PhunInteriors/manifest"
local Scrub = require "PhunInteriors/scrub"
local Leash = {}
Core.modules.leash = Leash

-- ---------------------------------------------------------------------------
-- Containment, and the only way out.
--
-- Containment is a property of the space, not of the tiles. One bounding box
-- test per occupant covers roof access, neighbouring instances, wall breaches
-- and any teleport exploit, which is why the walls themselves can be as
-- destructible as we like.
--
-- B42 has no Lua hook on door opening, so the exit is positional too. That
-- makes the exit test and the containment test the same test with different
-- outcomes, and both live in this one handler.
-- ---------------------------------------------------------------------------

local INTERVAL_MS = 250
local nextCheck = 0

--- Where is this player relative to their room?
-- Returns "inside", "exit" or "outside".
function Leash.classify(occupancy, x, y, z)
    local set = Core.roomSets[occupancy.roomSet]
    if not set then
        return "outside"
    end

    if Core.isExitSquare(set, occupancy.index, x, y, z) then
        return "exit"
    end

    local bounds = Core.slotBounds(set, occupancy.index)
    if Core.inBounds(bounds, x, y, z) then
        return "inside"
    end

    return "outside"
end

--- Should the leash ignore this player entirely?
--
-- There is no "an admin is debugging" flag in B42, but noclip is close enough
-- to be a statement of intent: it is capability gated (vanilla ISAdminPowerUI
-- guards it with Capability.ToggleNoclipHimself) and GameServer knows about
-- it, so the flag reads correctly for a remote player. Walking through walls
-- and being ejected for doing so are incompatible.
--
-- This deliberately covers the exit tile as well as the box. While noclip is
-- on the player is outside the containment system altogether; turn it off and
-- the next tick treats them normally, so an admin who wandered out is then
-- returned to the vehicle the usual way.
function Leash.isExempt(player)
    if not Core.settings.AdminNoClipExempt then
        return false
    end
    if not player.isNoClip or not player:isNoClip() then
        return false
    end
    return Core.tools.isAdmin(player)
end

--- First lease blueprint capture, driven off the containment test.
--
-- "The leash can see this player inside this room" is exactly the condition a
-- capture needs: the chunk is loaded, and the player has only just arrived so
-- nothing has been touched. There is no cheaper moment, and waiting for a
-- timer would capture whatever the tenant had built by then.
local function attemptCapture(occupancy)
    -- Nothing to learn if the set ships this slot already.
    if Core.shippedBlueprint(occupancy.roomSet, occupancy.index) then
        occupancy.captureSlot = nil
        return
    end
    local captured, reason = Manifest.captureSlot(occupancy.roomSet, occupancy.index)
    occupancy.captureTries = (occupancy.captureTries or 0) + 1
    if captured then
        occupancy.captureSlot = nil
        return
    end
    if occupancy.captureTries >= Manifest.CAPTURE_ATTEMPTS then
        -- Give up rather than keep scanning a room that is now lived in.
        -- This slot resolves through Manifest.forSlot from here on, which
        -- means a sibling in the same set.
        occupancy.captureSlot = nil
        Core.logLn(string.format(
            "gave up capturing %s#%s after %d attempts (%s); it will fall back to a sibling room",
            tostring(occupancy.roomSet), tostring(occupancy.index),
            occupancy.captureTries, tostring(reason)))
    end
end

--- Scrub a slot that was handed over straight from quarantine.
--
-- Same reasoning as the capture above: this is the first moment the room's
-- chunk is certainly loaded. The tenant is standing in it and will see it
-- change, which is not lovely, but the alternative was that quarantined slots
-- were never reissued and the pool drained away.
local function attemptScrub(occupancy)
    local cleaned, why = Scrub.slot(occupancy.roomSet, occupancy.index)
    occupancy.scrubTries = (occupancy.scrubTries or 0) + 1
    if cleaned then
        occupancy.scrubOnArrival = nil
        return
    end
    if occupancy.scrubTries >= Manifest.CAPTURE_ATTEMPTS then
        occupancy.scrubOnArrival = nil
        Core.logLn(string.format(
            "gave up scrubbing %s#%s after %d attempts (%s); the tenant keeps the mess",
            tostring(occupancy.roomSet), tostring(occupancy.index),
            occupancy.scrubTries, tostring(why)))
    end
end

local function checkOne(player, occupancy)
    local where = Leash.classify(occupancy, player:getX(), player:getY(), player:getZ())

    -- Capture and scrub both sit above every early return below. Neither is
    -- containment: they do not care whether this player is exempt or still
    -- inside their arrival grace, only that they are standing in the room.
    -- Capture sat under the exemption at first, so an admin with noclip on --
    -- the normal state while testing -- never captured a single blueprint.
    if where == "inside" then
        if occupancy.captureSlot then
            attemptCapture(occupancy)
        elseif occupancy.scrubOnArrival then
            attemptScrub(occupancy)
        elseif occupancy.powerPending then
            -- Same reasoning as the two above, and deliberately after them:
            -- the generator is filled once the room is settled, so a slot that
            -- is about to be scrubbed is not lit and then wiped. One shot --
            -- if there is no generator to find, that is a map problem and a
            -- retry will not conjure one.
            occupancy.powerPending = nil
            require("PhunInteriors/power").engage(occupancy)
        end
    end

    -- Logged on the transition only; this runs four times a second.
    if Leash.isExempt(player) then
        if not occupancy.unleashed then
            occupancy.unleashed = true
            Core.debugLn("leash off for " .. tostring(Core.playerKey(player)) .. " (admin noclip)")
        end
        return
    elseif occupancy.unleashed then
        occupancy.unleashed = nil
        Core.debugLn("leash back on for " .. tostring(Core.playerKey(player)))
    end

    -- The teleport is a client side action, so on a dedicated server the new
    -- position takes a round trip to get back here, and the destination chunk
    -- may still be streaming. Without this the leash sees the player at the
    -- vehicle, calls it a breach and ejects them the instant they enter.
    if occupancy.graceUntil and getTimestampMs() < occupancy.graceUntil then
        return
    end

    if where == "inside" then
        return
    end

    if where == "exit" then
        Transit.leave(player, "exit")
        return
    end

    -- Outside the box. Either they broke the shell or something moved them
    -- there. Same answer as the door: back to the vehicle.
    if Core.settings.BreachEjects then
        local b = Core.slotBounds(Core.roomSets[occupancy.roomSet], occupancy.index)
        Core.debugLn(string.format(
            "leash tripped for %s at %s,%s,%s; %s#%s is %s-%s x %s-%s z %s",
            tostring(Core.playerKey(player)),
            tostring(player:getX()), tostring(player:getY()), tostring(player:getZ()),
            tostring(occupancy.roomSet), tostring(occupancy.index),
            tostring(b.x1), tostring(b.x2), tostring(b.y1), tostring(b.y2), tostring(b.z)))
        Transit.leave(player, "breach")
    else
        -- Containment without ejection: put them back on the spawn tile.
        local set = Core.roomSets[occupancy.roomSet]
        local spawn = Core.slotSpawn(set, occupancy.index)
        Core.respond(player, Core.commands.teleport, {
            x = spawn.x,
            y = spawn.y,
            z = spawn.z,
            inside = true,
            reason = "leash"
        })
    end
end

function Leash.tick()
    local now = getTimestampMs()
    if now < nextCheck then
        return
    end
    nextCheck = now + INTERVAL_MS

    if Core.tools.isEmpty(Core.occupants) then
        return
    end

    -- Core.tools normalises this across SP, coop host and dedicated
    local players = Core.tools.onlinePlayers()
    if not players then
        return
    end

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then
            local occupancy = Core.occupants[Core.playerKey(player)]
            if occupancy then
                checkOne(player, occupancy)
            end
        end
    end
end

return Leash
