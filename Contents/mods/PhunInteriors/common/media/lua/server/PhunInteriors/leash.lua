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
--
-- Returns "inside" or "outside", and for "outside" also which edge of the box
-- they are beyond -- "north", "south", "east", "west" -- or nil when they are
-- over no edge at all, which is what the roof is, or when the room has gone
-- and there is no box to be beyond.
--
-- The edge is what makes a way out mean something. Where the room ends is the
-- one thing the room and the vehicle can both answer however differently they
-- are shaped, so "you left by the north wall" survives the translation to a
-- van where "you left 3.2 squares along the east side" never could.
--
-- Nothing here knows about cabs. The edge is a fact about the room; what that
-- edge leads to is a fact about the room's contract, and Transit.leave is
-- where the two meet.
function Leash.classify(occupancy, x, y, z)
    local room = Core.rooms[occupancy.room]
    if not room then
        return "outside", nil
    end

    -- The floor, not the footprint: the footprint's south row and east column
    -- are on the far side of their walls. See Core.slotFloor.
    local bounds = Core.slotFloor(room, occupancy.index)
    if Core.inBounds(bounds, x, y, z) then
        return "inside", nil
    end

    return "outside", Core.edgeCrossed(bounds, x, y)
end

--- Should the leash ignore this player entirely?
--
-- There is no "an admin is debugging" flag in B42, but noclip is close enough
-- to be a statement of intent: it is capability gated (vanilla ISAdminPowerUI
-- guards it with Capability.ToggleNoclipHimself) and GameServer knows about
-- it, so the flag reads correctly for a remote player. Walking through walls
-- and being ejected for doing so are incompatible.
--
-- This deliberately covers every way out, not just the box. While noclip is
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
    -- Nothing to learn if THIS SLOT has already captured. Deliberately not
    -- "can this slot be resolved" -- resolution falls back to a sibling, and
    -- gating on that would mean the first slot to capture froze the whole room
    -- at its decor and no other stamp ever recorded its own.
    if Manifest.hasCapture(occupancy.room, occupancy.index) then
        occupancy.captureSlot = nil
        return
    end
    local captured, reason = Manifest.captureSlot(occupancy.room, occupancy.index)
    occupancy.captureTries = (occupancy.captureTries or 0) + 1
    if captured then
        occupancy.captureSlot = nil
        return
    end
    if occupancy.captureTries >= Manifest.CAPTURE_ATTEMPTS then
        -- Give up rather than keep scanning a room that is now lived in.
        -- The slot's one window is gone with it -- Slots.markUsed will not
        -- open another, because after a tenant the room is no longer evidence
        -- of anything -- so this slot resolves through a sibling from here on
        -- and is restored to somebody else's decor. Rare, because capture
        -- rides the leash and so runs with the chunk provably loaded.
        occupancy.captureSlot = nil
        Core.logLn(string.format("gave up capturing %s#%s after %d attempts (%s); it will fall back to a sibling slot",
            tostring(occupancy.room), tostring(occupancy.index), occupancy.captureTries, tostring(reason)))
    end
end

--- Scrub a slot that was handed over straight from quarantine.
--
-- Same reasoning as the capture above: this is the first moment the room's
-- chunk is certainly loaded. The tenant is standing in it and will see it
-- change, which is not lovely, but the alternative was that quarantined slots
-- were never reissued and the pool drained away.
local function attemptScrub(occupancy)
    local cleaned, why = Scrub.slot(occupancy.room, occupancy.index)
    occupancy.scrubTries = (occupancy.scrubTries or 0) + 1
    if cleaned then
        occupancy.scrubOnArrival = nil
        return
    end
    if occupancy.scrubTries >= Manifest.CAPTURE_ATTEMPTS then
        occupancy.scrubOnArrival = nil
        Core.logLn(string.format("gave up scrubbing %s#%s after %d attempts (%s); the tenant keeps the mess",
            tostring(occupancy.room), tostring(occupancy.index), occupancy.scrubTries, tostring(why)))
    end
end

-- How often to look at the room's generator while somebody is in there.
local POWER_INTERVAL_MS = 30000

--- Keep the room's generator fed while the tenant is in it.
--
-- Deliberately not one-shot. A tenant who stays long enough to burn a full
-- tank would otherwise watch the lights die while their van sits outside with
-- a charged battery, and the room cannot read that battery to know better --
-- Power.syncRoom works it out from the ledger instead.
--
-- Every 30s rather than every tick: this reads a square and scans its objects,
-- and the leash runs four times a second.
local function attemptPower(occupancy)
    local now = getTimestampMs()
    if occupancy.powerNext and now < occupancy.powerNext then
        return
    end
    occupancy.powerNext = now + POWER_INTERVAL_MS
    require("PhunInteriors/power").syncRoom(occupancy.room, occupancy.index, occupancy.vehicleId)
end

local function checkOne(player, occupancy)
    local where, edge = Leash.classify(occupancy, player:getX(), player:getY(), player:getZ())

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
        else
            attemptPower(occupancy)
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

    -- Outside the box: a doorway, a hole in the wall, a window, or something
    -- that moved them. All the same answer -- back to the vehicle -- differing
    -- only in which part of it they land at, which is what `edge` carries.
    if Core.settings.BreachEjects then
        -- nil when the room has gone out from under a live occupancy, which is
        -- itself a reason to eject rather than a reason to stop.
        local b = Core.slotFloor(Core.rooms[occupancy.room], occupancy.index) or {}
        Core.debugLn(string.format("leash tripped for %s at %s,%s,%s; %s#%s is %s-%s x %s-%s z %s",
            tostring(Core.playerKey(player)), tostring(player:getX()), tostring(player:getY()), tostring(player:getZ()),
            tostring(occupancy.room), tostring(occupancy.index), tostring(b.x1), tostring(b.x2), tostring(b.y1),
            tostring(b.y2), tostring(b.z)))
        Transit.leave(player, "breach", edge)
    else
        -- Containment without ejection: put them back on the spawn tile.
        local room = Core.rooms[occupancy.room]
        local spawn = Core.slotSpawn(room, occupancy.index)
        if spawn then
            Core.respond(player, Core.commands.teleport, {
                x = spawn.x,
                y = spawn.y,
                z = spawn.z,
                inside = true,
                reason = "leash"
            })
        else
            -- There is no room to put them back into. Containment cannot mean
            -- "stay where you are" here, so fall through to the exit.
            Core.logLn("no spawn tile for " .. tostring(occupancy.room) .. "#" .. tostring(occupancy.index) ..
                           "; leaving instead of containing")
            Transit.leave(player, "breach", edge)
        end
    end
end

function Leash.tick()
    -- Before anything else, including reading the clock. This runs on OnTick,
    -- so it is entered sixty times a second for the life of the server, and
    -- almost always there is nobody in a room at all -- an empty map used to
    -- cost a getTimestampMs() call per tick to work that out.
    --
    -- One integer compare instead. NOT an add/remove of the OnTick handler,
    -- which is the obvious alternative and is a trap: Event.trigger walks its
    -- callbacks by index, re-reading size() each time round, so removing one
    -- during dispatch shifts the list under the cursor and silently SKIPS the
    -- next handler -- somebody else's, from another mod. And the exit path
    -- runs from inside this very tick, which is exactly when we would be
    -- unregistering. It does not throw; it just quietly drops a callback.
    if not Transit.anyoneInside() then
        return
    end

    local now = getTimestampMs()
    if now < nextCheck then
        return
    end
    nextCheck = now + INTERVAL_MS

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
