-- No isClient() guard, unlike every other file in this folder. Adding two
-- entries to a loot table is harmless on a client, and this has to be in place
-- wherever the loot roll actually happens.
require "PhunInteriors/registry"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Where a rain reservoir kit can turn up in the world.
--
-- Deliberately very rare. The kit is meant to be crafted by somebody skilled
-- or bought, and a room's water supply found lying in a crate would undercut
-- both. For scale: the rarest thing vanilla puts in CrateCarpentry is a wood
-- axe at 0.025, and this is well under half of that.
-- ---------------------------------------------------------------------------

local WEIGHT = 0.01
local LISTS = {"CrateCarpentry", "CrateFarming"}

Events.OnPostDistributionMerge.Add(function()
    if not ProceduralDistributions or not ProceduralDistributions.list then
        return
    end
    for _, name in ipairs(LISTS) do
        local list = ProceduralDistributions.list[name]
        if list and list.items then
            table.insert(list.items, Core.consts.reservoirItem)
            table.insert(list.items, WEIGHT)
        end
    end
end)
