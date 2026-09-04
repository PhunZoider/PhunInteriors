if isServer() then
    return
end
require "PhunInteriors/bounds"
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
end
