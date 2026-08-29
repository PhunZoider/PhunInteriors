if isServer() then
    return
end
require "PhunInteriors/bounds"
require "PhunInteriors/client_main"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- Refuse the player actions that would dismantle a room.
--
-- Deliberately narrow: this stops casual demolition, it is not what contains
-- the player. Containment is the leash, server side, and it works whether or
-- not these guards hold.
-- ---------------------------------------------------------------------------

local function refuse(player)
    if player then
        player:setHaloNote(getText("IGUI_PhunInteriors_CannotDamage"), 255, 180, 60, 300)
    end
end

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
end
