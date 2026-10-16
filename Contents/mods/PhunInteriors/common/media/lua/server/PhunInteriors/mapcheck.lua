if isClient() then
    return
end
require "PhunInteriors/registry"
require "PhunInteriors/tools"
local Core = PhunInteriors
local MapCheck = {}
Core.modules.mapcheck = MapCheck

-- ---------------------------------------------------------------------------
-- Whether the world actually has the rooms the registry points at.
--
-- A room is coordinates, and those only mean something if a map put a room
-- there. Three ways that goes wrong, all of which used to surface as late as
-- placeInside's isValidSquare test, after the entry action and after a slot
-- had been leased, with "no free room" as the reason:
--
--   * the map is not installed, or not in the server's Map= list;
--   * it is installed but the world predates it, so its cells are not in this
--     world's meta grid;
--   * another map shipping the same cell won, and has no room there.
--
-- isValidSquare cannot tell any of those apart from a working map once some
-- other map extends the grid past our block: it is a bounds test and nothing
-- else. So the test is the one the map itself answers -- does the meta grid
-- hold a room def over this slot's floor. countRoomsIntersecting reads the
-- lotheaders, which are loaded for every cell at boot, so it answers with the
-- room's chunk unloaded, which it always is when somebody asks to go in.
--
-- What this cannot see is a save that loaded our cells as bare ground before
-- the map was enabled (Docs/existing-save.md): the room defs are there, the
-- saved chunks are woods. Only loading the chunk can tell, and nobody is near
-- it at boot.
--
-- An answer the engine would not give -- no grid yet, a call that threw -- is
-- "present" and is not remembered. Refusing every room on a probe that failed
-- would be this mod breaking itself on a guess.
-- ---------------------------------------------------------------------------

MapCheck.DIR = "phuninteriors"

-- "x,y,z,w,h" of a slot's floor -> true/false. Keyed by geometry rather than
-- room and index, so an editor move is a different key and is asked afresh.
local known = {}

local function grid()
    local world = getWorld and getWorld()
    return world and world.getMetaGrid and world:getMetaGrid() or nil
end

--- Does the map have a room over this slot? True when it cannot tell.
function MapCheck.slotOnMap(roomId, index)
    local room = Core.rooms[roomId]
    local floor = room and Core.slotFloor(room, index)
    if not floor then
        return true
    end
    local w, h = floor.x2 - floor.x1 + 1, floor.y2 - floor.y1 + 1
    local key = string.format("%d,%d,%d,%d,%d", floor.x1, floor.y1, floor.z or 0, w, h)
    if known[key] ~= nil then
        return known[key]
    end
    local metaGrid = grid()
    if not metaGrid then
        return true
    end
    local ok, count = pcall(function()
        return metaGrid:countRoomsIntersecting(floor.x1, floor.y1, w, h)
    end)
    if not ok or type(count) ~= "number" then
        return true
    end
    known[key] = count > 0
    return known[key]
end

--- Does any slot of this room exist on the map?
function MapCheck.roomOnMap(roomId)
    local room = Core.rooms[roomId]
    if not room then
        return false
    end
    for _, index in ipairs(room.indices or {}) do
        if MapCheck.slotOnMap(roomId, index) then
            return true
        end
    end
    return false
end

--- Whether our map folder is in this world's map list. Nil when unknown.
function MapCheck.installed()
    if not getLotDirectories then
        return nil
    end
    local ok, dirs = pcall(getLotDirectories)
    if not ok or not dirs then
        return nil
    end
    for i = 0, dirs:size() - 1 do
        if dirs:get(i) == MapCheck.DIR then
            return true
        end
    end
    return false
end

--- Every registered slot, sorted into present and missing.
-- Returns {slots, missing, cells = {"88,46" = {rooms}}, rooms = {id = missing count}}
function MapCheck.survey()
    local result = {
        slots = 0,
        missing = 0,
        cells = {},
        rooms = {}
    }
    for roomId, room in pairs(Core.rooms) do
        for _, index in ipairs(room.indices or {}) do
            result.slots = result.slots + 1
            if not MapCheck.slotOnMap(roomId, index) then
                result.missing = result.missing + 1
                result.rooms[roomId] = (result.rooms[roomId] or 0) + 1
                local o = Core.slotOrigin(room, index)
                local cell = string.format("%d,%d", math.floor(o.x / 256), math.floor(o.y / 256))
                result.cells[cell] = result.cells[cell] or {}
                result.cells[cell][roomId] = true
            end
        end
    end
    return result
end

local last

--- Log what is missing, once, after the world's map data is final.
--
-- OnLoadedMapZones on a server and in single player: OnInitGlobalModData is
-- earlier than the save's meta grid load. Silent when every slot is there.
function MapCheck.report()
    last = MapCheck.survey()
    local installed = MapCheck.installed()
    if installed == false then
        Core.logLn("WARNING: the " .. MapCheck.DIR .. " map is not in this world's map list. Every room this mod" ..
                       " ships is refused until it is: add it to Map= ahead of Muldraugh, KY, e.g. " ..
                       MapCheck.DIR .. ";Muldraugh, KY")
    end
    if last.missing == 0 then
        Core.debugLn(string.format("map: all %d registered slot(s) have a room on the map", last.slots))
        return last
    end
    Core.logLn(string.format("WARNING: %d of %d registered slot(s) have no room on the map, and entry to them" ..
                                 " is refused.", last.missing, last.slots))
    local cells = {}
    for cell in pairs(last.cells) do
        table.insert(cells, cell)
    end
    table.sort(cells)
    for _, cell in ipairs(cells) do
        local rooms = {}
        for roomId in pairs(last.cells[cell]) do
            table.insert(rooms, roomId)
        end
        table.sort(rooms)
        Core.logLn("  cell " .. cell .. ": " .. table.concat(rooms, ", "))
    end
    if installed then
        Core.logLn("  The map is installed, so this world most likely predates those cells, or another map" ..
                       " ships the same cells and won. See Docs/existing-save.md.")
    end
    return last
end

--- Tell a player who has just logged in, when there is something to tell.
--
-- Everybody hears it when nothing at all is reachable, because otherwise every
-- player finds out one refused vehicle at a time. Only admins hear about a
-- partial gap: an ordinary player is told at the vehicle, if they ever reach
-- one of the missing rooms, and can do nothing about it before then.
function MapCheck.alert(player)
    if not last then
        MapCheck.report()
    end
    if last.missing == 0 then
        return
    end
    local key
    if last.missing >= last.slots then
        key = "IGUI_PhunInteriors_MapMissingAll"
    elseif Core.tools.isAdmin(player) then
        key = "IGUI_PhunInteriors_MapMissingSome"
    end
    if key then
        Core.respond(player, Core.commands.notify, {
            text = key,
            warning = true
        })
    end
end

-- For a spec: forget every remembered answer.
function MapCheck.reset()
    known = {}
    last = nil
end

return MapCheck
