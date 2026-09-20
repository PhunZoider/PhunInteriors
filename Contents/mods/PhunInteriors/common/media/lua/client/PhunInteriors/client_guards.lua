if isServer() then
    return
end
require "PhunInteriors/bounds"
require "PhunInteriors/holders"
require "PhunInteriors/client_main"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- Refuse the player actions that would dismantle a room.
--
-- Deliberately narrow: this stops casual demolition, it is not what contains
-- the player. Containment is the leash, server side, and it works whether or
-- not these guards hold.
--
-- Installed on demand rather than at file scope. ISDestroyStuffAction lives in
-- vanilla's shared/TimedActions and ISDestroyCursor in server/BuildingObjects,
-- and neither is guaranteed to have been loaded by the time our client folder
-- is. Hooking at load time would silently no-op if we won the race, which is
-- the worst of both worlds. Client.installGuards is called from the deferred
-- setup in client_events, by which point all lua is in.
-- ---------------------------------------------------------------------------

local installed = false

local function refuse(player)
    if player then
        player:setHaloNote(getText("IGUI_PhunInteriors_CannotDamage"), 255, 180, 60, 300)
    end
end

--- Say why a leased world object will not be packed away, but not every frame.
--
-- ISMoveableCursor asks canPickUpMoveable once per frame of hovering, so an
-- unthrottled note would repaint itself sixty times a second for as long as
-- the player looked at the tent. The refusal itself is silent and instant;
-- this is only the explanation, and one every few seconds is plenty.
local CARRY_NOTE_MS = 3000
local lastCarryNote = 0

--- Say, once in a while, that a bound moveable was allowed through unlocked.
--
-- Diagnostic rather than behaviour, and it exists because "the guard did not
-- fire" has two very different causes that look identical from the outside:
-- the lease really is free to go, or the flag never reached the tile the
-- player happened to click. The first is silent in the log and the second
-- names the object, so the next report can say which.
local function noteUnlocked(square)
    local objects = square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local object = objects:get(i)
        local item = object and Core.moveableItemOf(object)
        if item and Core.objectHasRooms(object) then
            local now = getTimestampMs()
            if now - lastCarryNote >= CARRY_NOTE_MS then
                lastCarryNote = now
                Core.debugLn("pickup allowed: " .. tostring(item) .. " at " .. tostring(square:getX()) ..
                                 "," .. tostring(square:getY()) .. " carries no lock on this tile" ..
                                 " (id " .. tostring(Core.objectId(object, false)) .. ")")
            end
            return
        end
    end
end

local function refuseCarry(player, reason)
    if not player then
        return
    end
    local now = getTimestampMs()
    if now - lastCarryNote < CARRY_NOTE_MS then
        return
    end
    lastCarryNote = now
    local text = (reason == "occupied") and "IGUI_PhunInteriors_HolderOccupied" or
                     "IGUI_PhunInteriors_HolderNotEmpty"
    player:setHaloNote(getText(text), 255, 180, 60, 300)
end

function Client.installGuards()
    if installed then
        return
    end
    installed = true

    --- Block the sledgehammer style destroy action inside a room.
    if ISDestroyStuffAction then
        local baseIsValid = ISDestroyStuffAction.isValid
        function ISDestroyStuffAction:isValid()
            if Core.settings.HardenShell and Core.objectIsOurs(self.item) then
                return false
            end
            return baseIsValid(self)
        end

        local baseStart = ISDestroyStuffAction.start
        function ISDestroyStuffAction:start()
            if Core.settings.HardenShell and Core.objectIsOurs(self.item) then
                refuse(self.character)
                self:forceStop()
                return
            end
            return baseStart(self)
        end
    else
        Core.logLn("ISDestroyStuffAction not loaded; sledgehammer guard is off")
    end

    --- And the build-menu destroy cursor, which is a separate path.
    if ISDestroyCursor then
        local baseIsValid = ISDestroyCursor.isValid
        function ISDestroyCursor:isValid(square)
            if Core.settings.HardenShell and square and
                Core.isOurSpace(square:getX(), square:getY(), square:getZ()) then
                return false
            end
            return baseIsValid(self, square)
        end
    else
        Core.logLn("ISDestroyCursor not loaded; destroy cursor guard is off")
    end

    -- -----------------------------------------------------------------------
    -- And packing away a tent somebody is living in.
    --
    -- Unlike the two above, this one is not merely tidiness. A tent's lease id
    -- cannot survive a pickup -- ForceSingleItem rebuilds the item from the
    -- anchor sprite and carries modData only when the CLICKED tile happens to
    -- be an IsoThumpable, which of one tent's tiles some are and some are not
    -- -- so a tent put back down would mint a fresh id and take a fresh room,
    -- leaving the old one leased to nobody with a tenant's belongings in it.
    -- Refusing the pickup is what makes that unreachable.
    --
    -- canPickUpMoveable is the single choke point: ISMoveableCursor asks it
    -- for the cursor's own verdict and ISMoveableTools asks it for the menu,
    -- so one hook covers both. Its multi-sprite branch asks once for the
    -- clicked square and then walks the grid through the *Internal form, which
    -- is why this reads the SQUARE -- the object argument is nil for some grid
    -- members and the square never is.
    --
    -- Refusing by returning false is exactly how vanilla refuses a rain
    -- collector holding fluid, four lines further down the same function, so
    -- the cursor already knows how to draw this.
    -- NO CHEAT BYPASS, and that is a change of mind worth recording.
    --
    -- This first mirrored vanilla's `ISMoveableDefinitions.cheat or
    -- character:isMovablesCheat()`, on the reasoning that an admin should have
    -- a way past a flag that had gone stale. It made the guard invisible to
    -- precisely the person testing it: movables cheat is a tickbox in the same
    -- admin power panel as noclip, so the first in-game test of this guard was
    -- run with it silently disabled, and the tent picked up as though nothing
    -- had been built.
    --
    -- It is the wrong reading anyway. Vanilla's cheat skips REQUIREMENTS --
    -- the skill, the tool, the weight you could carry -- and this is not one.
    -- Picking the tent up orphans a lease and destroys a tenant's belongings,
    -- and that is equally true of an admin. An admin who wants the tent back
    -- has Release in the room list, which drops the lease and clears the lock
    -- properly.
    if ISMoveableSpriteProps then
        local baseCanPickUp = ISMoveableSpriteProps.canPickUpMoveable
        function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
            local locked, reason = Core.lockedObjectOn(square)
            if locked then
                refuseCarry(character, reason)
                return false
            end
            noteUnlocked(square)
            return baseCanPickUp(self, character, square, object)
        end
    else
        Core.logLn("ISMoveableSpriteProps not loaded; the tent pickup guard is off")
    end
end
