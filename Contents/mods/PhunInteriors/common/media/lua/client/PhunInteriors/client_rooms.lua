if isServer() then
    return
end
require "PhunInteriors/client_main"
require "PhunInteriors/ui/shell"
local Core = PhunInteriors
local Client = Core.client

-- ---------------------------------------------------------------------------
-- The way into the registry editor.
--
-- This file used to BE the window: a collapsable window with a room list in
-- the top third and a slot list below it, drawn by hand. It is now three lines
-- in front of ui/shell.lua, and the move was forced by the map rather than
-- chosen for tidiness.
--
-- That window was built for two rooms of sixty slots. The shipped map is 81
-- rooms of about a dozen, so the ratio it was laid out around inverted: the
-- rooms became the long list and the slots became a detour off one. And the
-- payload it drew followed the same shape -- every slot of every room on every
-- refresh, which was 120 records and is 960, all but one room's worth of it
-- drawn by nothing.
--
-- It also could only ever LOOK. The registry is code, and `defaults.lua` is
-- generated from three CSVs, so there was no way to change a room from inside
-- the game and no way to keep a change if there had been. That is what the
-- override layer and PhunInteriors.json are for; see overrides.lua.
--
-- Client.openRooms is kept as the name, because client_admin.lua, the debug
-- menu entry and PhunInteriors.roomList() all call it, and renaming a function
-- to say "shell" instead of "rooms" would be churn in three files to describe
-- the same act of opening one window.
-- ---------------------------------------------------------------------------

--- Open the editor, or bring it forward if it is already open.
function Client.openRooms(player)
    return Core.ui.shell.open(player)
end

return Core.ui.shell
