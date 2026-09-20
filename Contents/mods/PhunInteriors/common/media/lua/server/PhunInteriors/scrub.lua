if isClient() then
    return
end
require "PhunInteriors/registry"
local Core = PhunInteriors
local Manifest = require "PhunInteriors/manifest"
local Slots = require "PhunInteriors/slots"
local Scrub = {}
Core.modules.scrub = Scrub

-- ---------------------------------------------------------------------------
-- Restore a quarantined slot to its manifest.
--
-- This is an idempotent rebuild, not a diff. Clear every non structural object
-- in the bounds, then re-place the manifest fresh. Added furniture, smashed
-- walls, damaged walls and dragged furniture are then all the same operation,
-- and it does not matter how the room got into its current state.
--
-- Note this is a scrub, not a chunk revert. No Lua call reloads a chunk from
-- its lotpack; PZ persists modified chunks into the save. Because we author
-- every room, rebuilding from a manifest is equivalent in practice.
-- ---------------------------------------------------------------------------

--- Empty an object's container, salvaging first if asked.
local function drain(object, keepLoot, salvage)
    -- Containers hang off the object, never off the square.
    -- square:getContainer() does not exist and threw on the first scrub that
    -- ever ran; vanilla only ever calls getContainer() on an IsoObject.
    local container = object:getContainer()
    if not container then
        return
    end
    local items = container:getItems()
    if keepLoot and salvage and items then
        for i = 0, items:size() - 1 do
            table.insert(salvage, items:get(i))
        end
    end
    container:removeAllItems()
end

--- Recreate an object the way the engine would have, not as a bare IsoObject.
--
-- An object's behaviour lives in its class, and the class is chosen from the
-- sprite when the map loads. IsoObject.new always returns a plain IsoObject,
-- so a restored light switch was a picture of a switch with nothing behind it,
-- and a room whose switch had been destroyed could never have light again.
--
-- Vanilla makes exactly this decision in ISMoveableSpriteProps when it places
-- a fixture the player picked up (shared/Moveables/ISMoveableSpriteProps.lua
-- :2175-2196). This mirrors it branch for branch.
--
-- DOORS ARE THE ONE THAT MATTERS NOW, and they did not used to. While the exit
-- was a tile you stood on, a door that had become scenery was cosmetic -- you
-- left by standing on the square either way. The exit is the doorway itself
-- now, so a door that cannot open is a room nobody can leave, and the path
-- there is real: isStructural captures the door into the blueprint, a tenant
-- breaks it with HardenShell off, the slot is released, and the scrub puts
-- back a picture of a door for the next tenant to be sealed in by.
--
-- Two subtleties worth not losing:
--
--   * The flag says which way the object faces -- doorN means it lies on the
--     square's north edge -- and it is passed straight through as the `north`
--     argument. Getting it wrong puts a working door in the wrong wall.
--   * windowN and WindowN are different flags. Lowercase is a window,
--     capitalised is an empty window frame. Vanilla distinguishes them and so
--     does this.
--
-- IsoDoor takes the sprite NAME rather than the sprite, which is the overload
-- vanilla exercises; it also declares one taking an IsoSprite, with zero
-- vanilla lua uses, so this uses the tested one.
local function createFromSprite(square, name)
    local sprite = getSprite(name)
    if not sprite then
        Core.logLn("no sprite named '" .. tostring(name) .. "', skipping it")
        return nil
    end

    if sprite:getType() == IsoObjectType.lightswitch then
        local switch = IsoLightSwitch.new(getCell(), square, sprite, square:getRoomID())
        switch:addLightSourceFromSprite()
        return switch
    end

    local props = sprite:getProperties()
    if props then
        if props:has(IsoFlagType.doorN) or props:has(IsoFlagType.doorW) then
            return IsoDoor.new(getCell(), square, name, props:has(IsoFlagType.doorN))
        end
        if props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WallW) then
            return IsoThumpable.new(getCell(), square, name, props:has(IsoFlagType.WallN), {})
        end
        if props:has(IsoFlagType.windowN) or props:has(IsoFlagType.windowW) then
            local window = IsoWindow.new(getCell(), square, sprite, props:has(IsoFlagType.windowN))
            window:setIsLocked(false)
            return window
        end
        if props:has(IsoFlagType.WindowN) or props:has(IsoFlagType.WindowW) then
            return IsoWindowFrame.new(getCell(), square, sprite, props:has(IsoFlagType.WindowN))
        end
    end

    return IsoObject.new(getCell(), square, name)
end

--- Bring one square back to what the blueprint says it should hold.
--
-- This reconciles rather than rebuilds, and that is a reversal of the
-- original design. Rebuilding meant deleting every object and re-placing the
-- blueprint, which is uniform and appealing right up until you notice the
-- re-placed objects are dead.
--
-- The engine picks an object's class from its sprite when the map loads: the
-- same call produces an IsoLightSwitch, an IsoDoor, an IsoThumpable. Lua
-- cannot ask for that. IsoObject.new gives a plain IsoObject, so a rebuilt
-- light switch is a picture of a light switch. Confirmed in game -- the
-- switches stopped working after the first scrub. Vanilla lua never
-- constructs one of these; it only ever tests with instanceof.
--
-- So anything the blueprint expects and the square already has is left where
-- it is, keeping whatever the engine made it. Only extras are removed, and
-- only genuinely missing objects are created, through createFromSprite so
-- they come back as the right class rather than as scenery.
--
-- It is also more idempotent than the rebuild was, not less: a second pass
-- over a restored room touches nothing at all.
local function reconcileSquare(square, wanted, keepLoot, salvage)
    local floor = square:getFloor()

    -- Sprites can legitimately repeat on one square, so count them rather
    -- than treating the blueprint as a set.
    local needed = {}
    for _, name in ipairs(wanted or {}) do
        needed[name] = (needed[name] or 0) + 1
    end

    local objects = square:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        if object and object ~= floor then
            local sprite = object:getSprite()
            local name = sprite and sprite:getName()

            if name and (needed[name] or 0) > 0 then
                -- Part of the room. Keep the object, empty anything the
                -- tenant stashed in it.
                needed[name] = needed[name] - 1
                drain(object, keepLoot, salvage)
            else
                if keepLoot and salvage and instanceof(object, "IsoWorldInventoryObject") then
                    local item = object:getItem()
                    if item then
                        table.insert(salvage, item)
                    end
                end
                drain(object, keepLoot, salvage)
                square:transmitRemoveItemFromSquare(object)
                square:RemoveTileObject(object)
            end
        end
    end

    -- Whatever is still owed was destroyed. This is the only path that mints a
    -- new object, and the only one that can produce an inert fixture.
    for name, count in pairs(needed) do
        for _ = 1, count do
            local object = createFromSprite(square, name)
            if object then
                square:AddTileObject(object)
                object:transmitCompleteItemToClients()
            end
        end
    end

    -- Corpses and blood do not belong to the next tenant. The square method is
    -- getDeadBodys, plural, returning a list -- getDeadBody(index) belongs to
    -- a hutch, not a square.
    local bodies = square:getDeadBodys()
    if bodies then
        for i = bodies:size() - 1, 0, -1 do
            local body = bodies:get(i)
            if body then
                -- vanilla removes from world first, then from the square
                body:removeFromWorld()
                body:removeFromSquare()
            end
        end
    end

    -- IsoGridSquare has no setBloodSplatLifetime. This pair is what vanilla
    -- ISCleanBlood:complete() uses.
    square:removeBlood(false, false)
    square:removeGrime()
end

--- Rebuild one slot from the manifest of its room.
-- Returns true plus any salvaged loot, or false plus a reason.
function Scrub.slot(roomId, index)
    local room = Core.rooms[roomId]
    if not room then
        return false, "unknown room"
    end

    -- Never over somebody's safehouse -- see Slots.safehouseOn. This is the
    -- one function every scrub goes through: the timer queue, the scrub on
    -- entry, the one on arrival and the admin command. Returned as an ordinary
    -- refusal, so the queue keeps the slot for later and the arrival scrub
    -- gives up after its attempts rather than retrying forever.
    local claim = Slots.safehouseOn(roomId, index)
    if claim then
        return false, "claimed as a safehouse by " .. tostring(claim:getOwner())
    end

    -- THIS SLOT's blueprint, so a stamp the author decorated differently is
    -- restored to what it actually was. Which source it came from is logged,
    -- because a scrub falling through to a sibling is about to overwrite
    -- whatever was painted here with a different slot's decor, and that should
    -- be visible rather than silent.
    local manifest, source = Manifest.forSlot(roomId, index)
    if not manifest then
        return false, "no blueprint for this slot yet"
    end

    local bounds = Core.slotBounds(room, index)
    local origin = Core.slotOrigin(room, index)
    if not bounds then
        return false, "no such slot in this room"
    end
    local keepLoot = Core.settings.ScrubKeepsLoot
    local salvage = keepLoot and {} or nil
    local touched = 0

    -- Verify the slot is loaded before mutating any of it, so a scrub is never
    -- left half applied.
    --
    -- Only the room's OWN level has to be there, which is the correction
    -- Manifest's scan needed first. A nil square above the room is empty air:
    -- an unroofed room has no z + 1 squares at all, and a roofed one has none
    -- over its south and east wall lines. Demanding them made every slot on
    -- the shipped map refuse every scrub as "chunk not loaded" -- and the
    -- scrub is also what takes an installed reservoir back down.
    for x = bounds.x1, bounds.x2 do
        for y = bounds.y1, bounds.y2 do
            if not getCell():getGridSquare(x, y, bounds.z) then
                return false, "chunk not loaded"
            end
        end
    end

    for z = bounds.z, bounds.z + 1 do
        for x = bounds.x1, bounds.x2 do
            for y = bounds.y1, bounds.y2 do
                local square = getCell():getGridSquare(x, y, z)
                if square then
                    local key = (x - origin.x) .. "," .. (y - origin.y) .. "," .. (z - origin.z)
                    -- through the resolver, because a manifest may be either
                    -- format: v2 stores palette indices, v1 stored names. nil
                    -- is meaningful: the blueprint says this square holds
                    -- nothing.
                    reconcileSquare(square, Manifest.spritesAt(manifest, key), keepLoot, salvage)
                    touched = touched + 1
                end
            end
        end
    end

    Core.logLn("scrubbed " .. roomId .. "#" .. index .. " (" .. touched ..
        " squares, from its " .. tostring(source) .. " blueprint)")
    return true, salvage
end

--- Reasons a deferral is the NORMAL state of a quarantined slot rather than
--- news. A released slot sits in the queue precisely because nobody is near
--- it, so its chunk is unloaded and stays unloaded, and a slot that never got
--- its one capture window has no blueprint and never will.
---
--- Both were logged on every pass, which is once per slot per ten minutes, for
--- as long as the queue is non-empty -- so the log filled with "deferring
--- scrub of ..." lines describing the system working exactly as designed.
--- CLAUDE.md's own rule about warnings applies: a message that fires when
--- nothing is wrong turns into noise nobody reads, and then the one that
--- matters is in it.
local EXPECTED = {
    ["chunk not loaded"] = true,
    ["no blueprint for this slot yet"] = true
}

--- Work the quarantine queue. Slots whose chunk is not loaded go back on the
--- queue and are retried on the next pass.
---
--- Still on a timer, and still only as OPPORTUNISTIC cleanup -- the pool does
--- not depend on it. A quarantined slot is scrubbed on arrival when it is next
--- handed out, which is the first moment its chunk is guaranteed to exist;
--- this catches the ones that happen to be loaded anyway.
function Scrub.processQueue(limit)
    limit = limit or 1
    local done = 0
    local deferred = {}

    while done < limit do
        local entry = Slots.nextQuarantined()
        if not entry then
            break
        end
        local ok, reason = Scrub.slot(entry.room, entry.index)
        if ok then
            done = done + 1
        else
            if not EXPECTED[reason] then
                -- Anything else IS news: an unknown room, a slot that is not
                -- in its room any more, a safehouse claim standing over one.
                Core.debugLn("deferring scrub of " .. entry.room .. "#" .. entry.index ..
                    ": " .. tostring(reason))
            end
            table.insert(deferred, entry)
            break
        end
    end

    local store = Slots.store()
    for _, entry in ipairs(deferred) do
        table.insert(store.quarantine, entry)
    end

    return done
end

return Scrub
