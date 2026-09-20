-- The occupancy count the leash gates on.
--
-- Worth its own file because the failure mode is the worst one this mod has:
-- if the count drifts below the truth, Leash.tick returns early while somebody
-- is standing in a room, and containment stops without a word. The count is
-- maintained by transitions rather than by counting the table, so the thing to
-- prove is that every odd sequence of writes still agrees with the table.
local ROOT = os.getenv("PI_ROOT") or "."
local stubs = dofile(ROOT .. "/Tests/lua/stubs.lua")
stubs.install(ROOT)

require "PhunInteriors/core"
require "PhunInteriors/registry"
local Core = PhunInteriors
Core.logLn = function()
end
Core.debugLn = function()
end

local Transit = require "PhunInteriors/transit"
local report = stubs.reporter()
local check = report.check

-- Grown a getModData because setOccupancy now also maintains the durable
-- entrance position, which lives there. A player without one is not a thing
-- that exists in game, and transit.lua deliberately does not guard for it.
local function player(name)
    local md = {}
    return {
        getUsername = function()
            return name
        end,
        getModData = function()
            return md
        end
    }
end

local bob, sue = player("bob"), player("sue")

check("nobody is inside to begin with", Transit.anyoneInside(), false)

Transit.setOccupancy(bob, {room = "r", index = 0})
check("one tenant registers", Transit.anyoneInside(), true)
check("and lands in the table", Core.occupants["bob"] ~= nil, true)

-- Re-entering without leaving. placeInside writes unconditionally, so this is
-- reachable, and a naive increment would leak a count that never comes back.
Transit.setOccupancy(bob, {room = "r", index = 1})
Transit.setOccupancy(bob, nil)
check("setting the same holder twice still clears in one", Transit.anyoneInside(), false)

-- Two tenants, one leaves. The other must still be watched: this is the case a
-- boolean rather than a count would get wrong.
Transit.setOccupancy(bob, {room = "r", index = 0})
Transit.setOccupancy(sue, {room = "r", index = 1})
Transit.setOccupancy(bob, nil)
check("one of two leaving leaves the other watched", Transit.anyoneInside(), true)
Transit.setOccupancy(sue, nil)
check("and the last one out turns it off", Transit.anyoneInside(), false)

-- Clearing somebody who was never inside. Transit.leave returns early on a
-- missing occupancy today, but nothing stops a future caller.
Transit.setOccupancy(sue, nil)
check("clearing an empty slot does not go negative", Transit.anyoneInside(), false)
Transit.setOccupancy(sue, {room = "r", index = 0})
check("and the count is still honest afterwards", Transit.anyoneInside(), true)
Transit.setOccupancy(sue, nil)
check("back to nobody", Transit.anyoneInside(), false)

-- The invariant itself, over a sequence chosen to be awkward: repeats,
-- clearing what is already clear, and interleaved holders. The count is
-- maintained by transitions, so agreeing with the table after every one of
-- them is the whole claim.
local who = {player("a"), player("b"), player("c")}
local script = {{1, true}, {2, true}, {1, true}, {1, false}, {3, true}, {3, false},
                {3, false}, {2, false}, {1, false}, {1, false}}
local drifted = false
for _, step in ipairs(script) do
    Transit.setOccupancy(who[step[1]], step[2] and {room = "r", index = 0} or nil)
    local n = 0
    for _ in pairs(Core.occupants) do
        n = n + 1
    end
    if (n > 0) ~= Transit.anyoneInside() then
        drifted = true
    end
end
check("the count never disagrees with the table", drifted, false)
check("and ends where the table does", Transit.anyoneInside(), false)

os.exit(report.finish("occupancy") == 0 and 0 or 1)
