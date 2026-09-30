if isClient() then
    return
end
-- Compatibility: PhunZones2. The display half.
--
-- A tenant is standing in our block, which PhunZones knows as a void (see
-- shared/PhunInteriors/compat_phunzones.lua), and its client shows a void as
-- whatever zone the server last pushed for that player. This is the pushing:
-- the zone of the thing they went in through, kept current while it moves.
--
-- Everything on the client is PhunZones' own, written for Project RV Interior
-- (PhunZones' rv_server.lua is the reference): `updateEffectiveZone` sets the
-- display zone and remembers it as `rvZone`, and a handler reapplies that
-- whenever the player's physical zone is recomputed.
--
-- Only a tenant standing in our block is pushed to. A room another mod
-- registered elsewhere (PhunTaxi's garage in 87,49, PhunRooms' 88,49) sits in
-- a zone of its own, which is not a void, and a push there is wrong twice
-- over: it names the town they came from instead of the room, and it sticks,
-- because PhunZones only recomputes the display zone when the physical one
-- changes. So a push made on the way in, before the teleport has landed, is
-- skipped, and the poll makes it a moment later.
--
-- Where "the thing they went in through" is, by holder kind:
--   vehicle, object  the lease's lastKnownVehiclePos. The tracker keeps it
--                    current while somebody drives, which is the only time it
--                    can change, so polling it is reading a table, not a sweep.
--   admin, room      the entrance in their player modData: where they stood
--                    when they went in. Several tenants of one holderless room
--                    each see their own town, because the entrance is per
--                    visit.
-- Falling back to the occupancy's returnTo, which is where an exit goes.
require "PhunInteriors/core"
local zones = require "PhunInteriors/compat_phunzones"
local Core = PhunInteriors

local Sync = {}

if not zones.active then
    return Sync
end

local Transit = require "PhunInteriors/transit"
local Slots = require "PhunInteriors/slots"

-- How often the poll runs, in seconds. rv_server.lua uses 2.
local INTERVAL = 2

-- player key -> the zone key last pushed to them, so a parked van is not
-- announced every two seconds.
local pushed = {}

local function holderPosition(player, occupancy)
    local kind = Core.holderKind(occupancy.vehicleId)
    if kind == "vehicle" or kind == "object" then
        local lease = Slots.find(occupancy.vehicleId)
        if lease and lease.lastKnownVehiclePos then
            return lease.lastKnownVehiclePos
        end
    end
    return Transit.entranceOf(player) or occupancy.returnTo
end

-- PhunZones' key for a position, or nil. pcalled because PhunZones is not a
-- dependency and its internals are not ours to trust, the way PhunTaxi names
-- a phone's region.
--
-- Our own key is refused. A van parked on the interior block, or an admin who
-- ported from one room into another, would otherwise push "Interior" as the
-- place the interior is, and the display would be the void naming itself.
local function keyAt(x, y)
    local pz = PhunZones
    if not (x and y and pz and pz.getLocation) then
        return nil
    end
    local ok, loc = pcall(pz.getLocation, x, y)
    return ok and type(loc) == "table" and loc.key or nil
end

local function zoneAt(position)
    local key = position and keyAt(position.x, position.y)
    if key == zones.zoneKey then
        return nil
    end
    return key
end

local function push(player, zone)
    local pz = PhunZones
    if Core.isLocal then
        -- Single player: no round trip, so do what PhunZones' client command
        -- handler does, in the same order.
        if pz.setEffectiveZone then
            pz.setEffectiveZone(player, zone)
            local md = player:getModData().PhunZones
            if md then
                md.rvZone = zone
            end
        end
        return
    end
    if pz.commands and pz.commands.updateEffectiveZone then
        sendServerCommand(player, pz.name, pz.commands.updateEffectiveZone, {
            player = player:getUsername(),
            zone = zone
        })
    end
end

--- Push this player's holder zone if it has changed since the last push.
--- `force` pushes even when it has not.
function Sync.update(player, force)
    local key = Core.playerKey(player)
    local occupancy = key and Core.occupants[key]
    if not occupancy then
        return
    end
    -- Not in our block: see the header. Nothing is recorded in `pushed`, so
    -- the first poll that finds them in it pushes.
    if keyAt(player:getX(), player:getY()) ~= zones.zoneKey then
        return
    end
    local zone = zoneAt(holderPosition(player, occupancy))
    if not zone or (zone == pushed[key] and not force) then
        return
    end
    Core.debugLn(string.format("%s's interior now shows as %s (was %s)", tostring(key), zone,
        tostring(pushed[key])))
    pushed[key] = zone
    push(player, zone)
end

-- Always pushed on the way in. A recovery on login fires this too, and that
-- is the one moment the client may have lost what it was last told.
Events[Core.events.OnEnter].Add(function(player)
    Sync.update(player, true)
end)

Events[Core.events.OnExit].Add(function(player)
    local key = Core.playerKey(player)
    if key then
        pushed[key] = nil
    end
end)

-- Always registered, gated on the occupancy count; see "The tick is always
-- registered" in CLAUDE.md for why this is never removed and re-added.
local nextCheck = 0
Events.OnTick.Add(function()
    if not Transit.anyoneInside() then
        return
    end
    local now = getTimestamp()
    if now < nextCheck then
        return
    end
    nextCheck = now + INTERVAL
    for key in pairs(Core.occupants) do
        local player = Core.tools.getPlayerByUsername(key)
        if player then
            Sync.update(player)
        end
    end
end)

return Sync
