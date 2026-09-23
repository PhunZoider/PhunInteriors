if isClient() then
    return
end
require "PhunInteriors/bounds"
require "PhunInteriors/tools"
local Core = PhunInteriors
local Harden = {}
Core.modules.harden = Harden

-- ---------------------------------------------------------------------------
-- Shell hardening.
--
-- Worth being precise about what this is and is not. B42 exposes getThumpable
-- on IsoObject but no setter, and no fire flags on IsoGridSquare, so we cannot
-- simply mark the walls invulnerable. What we can do is refuse the player
-- actions that destroy them and put out fires that start inside a room.
--
-- That is fine, because hardening is not what contains the player. The leash
-- is. This just stops a room being casually dismantled, and it is a sandbox
-- option precisely because a v2 siege will want it dialled down.
-- ---------------------------------------------------------------------------

--- Put out any fire burning inside a room a player currently occupies.
--
-- Per room rather than all or nothing: a room's own `hardenShell` beats the
-- sandbox option either way, so a hub stays fireproof on a server that lets
-- vehicle rooms burn, and the reverse.
function Harden.sweepFire()
    if Core.tools.isEmpty(Core.occupants) then
        return 0
    end

    local doused = 0
    local seen = {}

    for _, occupancy in pairs(Core.occupants) do
        local key = occupancy.room .. "#" .. occupancy.index
        if not seen[key] and Core.shellHardened(occupancy.room) then
            seen[key] = true
            local room = Core.rooms[occupancy.room]
            local bounds = room and Core.slotBounds(room, occupancy.index)
            if bounds then
                -- Both levels, like every other sweep over a slot. Fire
                -- spreads upward, and the power square lives at z+1.
                for z = bounds.z, bounds.z + 1 do
                    for x = bounds.x1, bounds.x2 do
                        for y = bounds.y1, bounds.y2 do
                            local square = getCell():getGridSquare(x, y, z)
                            if square and square:haveFire() then
                                -- Vanilla's own pair, from the fire brush tool
                                -- (FireBrushUI.lua:265). Both halves matter:
                                -- stopFire deregisters it properly and
                                -- transmitStopFire is what tells clients, which
                                -- a server side douse otherwise never does.
                                --
                                -- This used to be fire:removeFromWorld() on the
                                -- object from square:getFire(). That is
                                -- IsoObject's generic removal, and the engine
                                -- answered every call with "IsoFireManager.
                                -- Remove unknown fire, ignoring" -- so the same
                                -- fires were found and "doused" on every sweep,
                                -- forever, while continuing to burn.
                                --
                                -- extinctFire() and IsoFireManager.RemoveAllOn()
                                -- both exist and look right. Neither has a
                                -- single use in vanilla lua, which is the tell.
                                square:stopFire()
                                square:transmitStopFire()
                                doused = doused + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if doused > 0 then
        Core.debugLn("doused " .. doused .. " fire(s) inside rooms")
    end
    return doused
end

return Harden
