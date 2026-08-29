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
function Harden.sweepFire()
    if not Core.settings.HardenShell then
        return 0
    end
    if Core.tools.isEmpty(Core.occupants) then
        return 0
    end

    local doused = 0
    local seen = {}

    for _, occupancy in pairs(Core.occupants) do
        local key = occupancy.roomSet .. "#" .. occupancy.index
        if not seen[key] then
            seen[key] = true
            local set = Core.roomSets[occupancy.roomSet]
            if set then
                local bounds = Core.slotBounds(set, occupancy.index)
                for x = bounds.x1, bounds.x2 do
                    for y = bounds.y1, bounds.y2 do
                        local square = getCell():getGridSquare(x, y, bounds.z)
                        if square then
                            local fire = square:getFire()
                            if fire then
                                fire:removeFromWorld()
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
