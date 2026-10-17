if isServer() then
    return
end
require "ISUI/ISCollapsableWindowJoypad"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "PhunInteriors/ui/state"
local Core = PhunInteriors
local ListPanel = require "PhunInteriors/ui/list_panel"

-- ---------------------------------------------------------------------------
-- The vehicle bench: bind a vehicle pack one vehicle at a time.
--
-- The loop it is for is spawn, look, pick a room, walk in, walk out, next --
-- a hundred times over for a pack like PZK's. Typed into the console that is
-- three commands per vehicle and the room id from memory; here it is a
-- dropdown and two buttons.
--
-- Nothing in it is a new mechanism. Bind is the editBinding command the
-- Bindings tab sends, under an id of `bench.<script>`, so a bound vehicle is
-- an ordinary editor override and can be tested the moment it is made. The
-- spawn and the clearing are server/PhunInteriors/bench.lua.
--
-- What it adds is the record. Every decision is written to the game's Lua
-- folder on THIS machine, not the server's -- deliberately, since the files
-- are the author's working notes and the destination is Docs/pi-vehicles.csv:
--
--   PhunInteriors_bench.csv          the list to work through, read on Load.
--                                    vehicle,room[,anything,note]; the room is
--                                    a suggestion and may be blank.
--   PhunInteriors_bench_out.txt      every vehicle bound so far, as
--                                    vehicle,room,boarding -- the shape of
--                                    pi-vehicles.csv, ready to paste. A .txt
--                                    because getFileWriter refuses .csv: it
--                                    writes only ini, cfg, txt, log and json
--                                    (LuaManager.ALLOWED_FILE_EXTENSIONS) and
--                                    answers anything else with a silent nil.
--   PhunInteriors_bench_skipped.txt  every vehicle skipped, one per line.
--
-- Both outputs are read back on open, so a session survives a restart. The
-- bindings themselves do not unless the editor's Save is pressed, so a vehicle
-- recorded as bound is bound again on its next spawn.
-- ---------------------------------------------------------------------------

local FONT_SCALE = ListPanel.FONT_SCALE
local PAD = ListPanel.PAD
local FONT_HGT = ListPanel.FONT_HGT_SMALL
local H = FONT_HGT + 6

local IN_FILE = "PhunInteriors_bench.csv"
local OUT_FILE = "PhunInteriors_bench_out.txt"
local SKIP_FILE = "PhunInteriors_bench_skipped.txt"
local ROOM_PREFIX = "phun.room."
local BINDING_PREFIX = "bench."
local RADIUS = 5

-- Every boarding value the sheet uses. A free text box would accept a typo
-- that then silently boards at the default.
local BOARDING = {"", "door", "TruckBed", "TrunkDoor", "SeatRearRight", "SeatRearLeft"}

Core.ui.bench = ISCollapsableWindowJoypad:derive("PhunInteriorsBench")
local Bench = Core.ui.bench

local instance = nil

-- Module level, so closing the window does not lose the place.
local session = {
    queue = {},
    pos = 1,
    bound = {},
    skipped = {}
}

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

local function readLines(name)
    local reader = getFileReader(name, false)
    if not reader then
        return nil
    end
    local lines = {}
    local line = reader:readLine()
    while line do
        lines[#lines + 1] = line
        line = reader:readLine()
    end
    reader:close()
    return lines
end

--- Build the text first: getFileWriter truncates on open.
local function writeText(name, text)
    local writer = getFileWriter(name, true, false)
    if not writer then
        return false
    end
    writer:write(text)
    writer:close()
    return true
end

local function split(line)
    local out = {}
    for field in string.gmatch(line .. ",", "([^,]*),") do
        out[#out + 1] = field:gsub("^%s+", ""):gsub("%s+$", "")
    end
    return out
end

--- A room as the sheet writes it, `Van_Mechanic`, or as the registry does.
local function fullRoomId(text)
    if not text or text == "" then
        return nil
    end
    if Core.rooms[text] then
        return text
    end
    if Core.rooms[ROOM_PREFIX .. text] then
        return ROOM_PREFIX .. text
    end
    return nil
end

local function shortRoomId(id)
    if id and string.sub(id, 1, #ROOM_PREFIX) == ROOM_PREFIX then
        return string.sub(id, #ROOM_PREFIX + 1)
    end
    return id
end

local function loadRecord()
    session.bound, session.skipped = {}, {}
    for i, line in ipairs(readLines(OUT_FILE) or {}) do
        local f = split(line)
        if f[1] and f[1] ~= "" and not (i == 1 and f[1] == "vehicle") then
            session.bound[f[1]] = {room = fullRoomId(f[2]) or f[2], boarding = f[3] or ""}
        end
    end
    for _, line in ipairs(readLines(SKIP_FILE) or {}) do
        if line ~= "" then
            session.skipped[line] = true
        end
    end
end

local function saveRecord()
    local scripts = {}
    for script in pairs(session.bound) do
        scripts[#scripts + 1] = script
    end
    table.sort(scripts)
    local rows = {"vehicle,room,boarding"}
    for _, script in ipairs(scripts) do
        local entry = session.bound[script]
        rows[#rows + 1] = script .. "," .. tostring(shortRoomId(entry.room)) .. "," .. (entry.boarding or "")
    end
    writeText(OUT_FILE, table.concat(rows, "\n") .. "\n")

    local skipped = {}
    for script in pairs(session.skipped) do
        skipped[#skipped + 1] = script
    end
    table.sort(skipped)
    writeText(SKIP_FILE, table.concat(skipped, "\n") .. "\n")
end

---------------------------------------------------------------------------
-- What the registry already says
---------------------------------------------------------------------------

--- Rooms this script reaches through bindings other than the bench's own.
local function shippedRooms(script)
    local out, seen = {}, {}
    for id, binding in pairs(Core.bindings) do
        if binding.kind ~= "object" and string.sub(id, 1, #BINDING_PREFIX) ~= BINDING_PREFIX then
            for _, name in ipairs(binding.scripts or {}) do
                if name == script then
                    for _, roomId in ipairs(binding.rooms or {}) do
                        if not seen[roomId] then
                            seen[roomId] = true
                            out[#out + 1] = shortRoomId(roomId)
                        end
                    end
                end
            end
        end
    end
    table.sort(out)
    return out
end

local function isBoundAnywhere(script)
    return #shippedRooms(script) > 0 or session.bound[script] ~= nil
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Bench:new(x, y, width, height, player)
    local o = ISCollapsableWindowJoypad:new(x, y, width, height, player)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.backgroundColor = {r = 0, g = 0, b = 0, a = 0.8}
    o.moveWithMouse = true
    o:setResizable(false)
    return o
end

function Bench:button(x, y, label, handler, tooltip)
    local w = math.max(math.floor(60 * FONT_SCALE),
        getTextManager():MeasureStringX(UIFont.Small, label) + PAD * 2)
    local btn = ISButton:new(x, y, w, H, label, self, handler)
    btn:initialise()
    btn:instantiate()
    btn.tooltip = tooltip
    self:addChild(btn)
    return btn
end

function Bench:label(x, y, text)
    local lbl = ISLabel:new(x, y, H, text, 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    lbl:initialise()
    self:addChild(lbl)
    return lbl
end

function Bench:createChildren()
    ISCollapsableWindowJoypad.createChildren(self)
    local y = self:titleBarHeight() + PAD
    local inner = self.width - PAD * 2

    -- Where the list comes from.
    local x = PAD
    local load = self:button(x, y, getText("IGUI_PhunInteriors_Bench_Load"), Bench.onLoad,
        getText("IGUI_PhunInteriors_Bench_Tip_Load"))
    x = x + load:getWidth() + PAD
    local scan = self:button(x, y, getText("IGUI_PhunInteriors_Bench_Scan"), Bench.onScan,
        getText("IGUI_PhunInteriors_Bench_Tip_Scan"))
    x = x + scan:getWidth() + PAD
    local clearBtn = self:button(0, y, getText("IGUI_PhunInteriors_Bench_Clear"), Bench.onClear,
        getText("IGUI_PhunInteriors_Bench_Tip_Clear"))
    clearBtn:setX(self.width - PAD - clearBtn:getWidth())
    self._filter = ISTextEntryBox:new("pzk", x, y, clearBtn:getX() - PAD - x, H)
    self._filter:initialise()
    self._filter:instantiate()
    self._filter.tooltip = getText("IGUI_PhunInteriors_Bench_Tip_Filter")
    self:addChild(self._filter)
    y = y + H + PAD * 2

    -- Which vehicle, and what is already true of it. Drawn in render().
    self._infoY = y
    y = y + (FONT_HGT + 2) * 3 + PAD

    local labelW = math.max(getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_PhunInteriors_Lbl_Room")),
        getTextManager():MeasureStringX(UIFont.Small, getText("IGUI_PhunInteriors_Bench_Boarding"))) + PAD
    self:label(PAD, y, getText("IGUI_PhunInteriors_Lbl_Room"))
    self._roomCombo = ISComboBox:new(PAD + labelW, y, inner - labelW, H, self, nil)
    self._roomCombo:initialise()
    self._roomCombo:instantiate()
    self:addChild(self._roomCombo)
    y = y + H + PAD

    self:label(PAD, y, getText("IGUI_PhunInteriors_Bench_Boarding"))
    self._boardingCombo = ISComboBox:new(PAD + labelW, y, inner - labelW, H, self, nil)
    self._boardingCombo:initialise()
    self._boardingCombo:instantiate()
    for _, point in ipairs(BOARDING) do
        self._boardingCombo:addOptionWithData(point == "" and getText("IGUI_PhunInteriors_Bench_Default") or point,
            point)
    end
    self:addChild(self._boardingCombo)
    y = y + H + PAD * 2

    x = PAD
    local function add(label, handler, tooltip)
        local btn = self:button(x, y, getText(label), handler, tooltip and getText(tooltip))
        x = x + btn:getWidth() + PAD
        return btn
    end
    add("IGUI_PhunInteriors_Bench_Prev", Bench.onPrev)
    add("IGUI_PhunInteriors_Bench_Spawn", Bench.onSpawn, "IGUI_PhunInteriors_Bench_Tip_Spawn")
    local bind = add("IGUI_PhunInteriors_Bench_Bind", Bench.onBind, "IGUI_PhunInteriors_Bench_Tip_Bind")
    bind.backgroundColor = {r = 0.25, g = 0.55, b = 0.30, a = 0.9}
    bind.backgroundColorMouseOver = {r = 0.35, g = 0.70, b = 0.40, a = 1}
    add("IGUI_PhunInteriors_Bench_Unbind", Bench.onUnbind)
    add("IGUI_PhunInteriors_Bench_Skip", Bench.onSkip, "IGUI_PhunInteriors_Bench_Tip_Skip")
    add("IGUI_PhunInteriors_Bench_Next", Bench.onNext, "IGUI_PhunInteriors_Bench_Tip_Next")
    y = y + H + PAD

    self._statusY = y
    self:setHeight(y + FONT_HGT + PAD * 2)

    self:fillRooms()
    self:showCurrent()
end

--- Every room, by label, which is what an author picking one reads.
function Bench:fillRooms()
    local rooms = {}
    for id, room in pairs(Core.rooms) do
        rooms[#rooms + 1] = {id = id, label = room.label or id}
    end
    table.sort(rooms, function(a, b)
        return a.label < b.label
    end)
    self._roomCombo:clear()
    for _, room in ipairs(rooms) do
        self._roomCombo:addOptionWithData(room.label, room.id)
    end
    self._roomCombo.selected = #rooms > 0 and 1 or 0
end

---------------------------------------------------------------------------
-- The current vehicle
---------------------------------------------------------------------------

local function current()
    return session.queue[session.pos]
end

--- Point both dropdowns at what this vehicle was given, or was suggested.
function Bench:showCurrent()
    local entry = current()
    if not entry then
        return
    end
    local decided = session.bound[entry.script]
    local roomId = decided and decided.room or entry.suggest
    if roomId and Core.rooms[roomId] then
        self._roomCombo:selectData(roomId)
    end
    self._boardingCombo:selectData(decided and decided.boarding or "")
end

function Bench:render()
    ISCollapsableWindowJoypad.render(self)
    if self.isCollapsed then
        return
    end
    local y = self._infoY
    local entry = current()
    if not entry then
        self:drawText(getText("IGUI_PhunInteriors_Bench_Empty"), PAD, y, 0.8, 0.8, 0.8, 1, UIFont.Small)
    else
        self:drawText(string.format("%d / %d   %s", session.pos, #session.queue, entry.script), PAD, y,
            1, 1, 1, 1, UIFont.Small)
        y = y + FONT_HGT + 2

        local state, r, g, b
        if session.bound[entry.script] then
            state = getText("IGUI_PhunInteriors_Bench_State_Bound", shortRoomId(session.bound[entry.script].room))
            r, g, b = 0.45, 0.85, 0.5
        elseif session.skipped[entry.script] then
            state = getText("IGUI_PhunInteriors_Bench_State_Skipped")
            r, g, b = 0.95, 0.75, 0.4
        else
            state = getText("IGUI_PhunInteriors_Bench_State_Open")
            r, g, b = 0.8, 0.8, 0.8
        end
        if entry.note and entry.note ~= "" then
            state = state .. "   " .. entry.note
        end
        self:drawText(state, PAD, y, r, g, b, 1, UIFont.Small)
        y = y + FONT_HGT + 2

        local shipped = shippedRooms(entry.script)
        if #shipped > 0 then
            self:drawText(getText("IGUI_PhunInteriors_Bench_Shipped", table.concat(shipped, ", ")), PAD, y,
                0.6, 0.75, 0.95, 1, UIFont.Small)
        end
    end

    if self._status then
        self:drawText(self._status, PAD, self._statusY, 0.75, 0.85, 0.75, 1, UIFont.Small)
    end
end

function Bench:say(text)
    self._status = text
end

--- The server's answer to whatever was last sent. client_commands.lua calls
--- this, as it does the shell's notice, so the result lands where somebody is
--- looking rather than only in the log.
function Bench:notice(lines)
    self:say(table.concat(lines, "; "))
end

---------------------------------------------------------------------------
-- Building the queue
---------------------------------------------------------------------------

function Bench:onLoad()
    local lines = readLines(IN_FILE)
    if not lines then
        self:say(getText("IGUI_PhunInteriors_Bench_NoFile", IN_FILE))
        return
    end
    local queue = {}
    for i, line in ipairs(lines) do
        local f = split(line)
        if f[1] and f[1] ~= "" and string.sub(f[1], 1, 1) ~= "#" and not (i == 1 and f[1] == "vehicle") then
            if getScriptManager():getVehicle(f[1]) then
                queue[#queue + 1] = {script = f[1], suggest = fullRoomId(f[2]), note = f[4]}
            end
        end
    end
    self:setQueue(queue, getText("IGUI_PhunInteriors_Bench_Loaded", #queue, IN_FILE))
end

--- Every loaded vehicle script whose name holds the filter text and that no
--- binding reaches yet. The catch-all for a pack nobody has written a list for.
function Bench:onScan()
    local filter = string.lower(self._filter:getText() or "")
    local queue = {}
    local all = getScriptManager():getAllVehicleScripts()
    for i = 0, all:size() - 1 do
        local name = all:get(i):getFullName()
        if (filter == "" or string.find(string.lower(name), filter, 1, true)) and not isBoundAnywhere(name) then
            queue[#queue + 1] = {script = name}
        end
    end
    table.sort(queue, function(a, b)
        return a.script < b.script
    end)
    self:setQueue(queue, getText("IGUI_PhunInteriors_Bench_Scanned", #queue))
end

--- Start at the first vehicle nobody has decided about yet.
function Bench:setQueue(queue, message)
    session.queue = queue
    session.pos = 1
    for i, entry in ipairs(queue) do
        if not session.bound[entry.script] and not session.skipped[entry.script] then
            session.pos = i
            break
        end
    end
    self:showCurrent()
    self:say(message)
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function sendBinding(script, roomId)
    Core.dispatch(Core.commands.editBinding, {
        binding = BINDING_PREFIX .. script,
        kind = "vehicle",
        scripts = {script},
        rooms = {roomId}
    })
end

local function sendBoarding(script, point)
    Core.admin("benchBoarding", {script = script, point = point})
    -- The client walks to the boarding point itself, and in multiplayer its
    -- registry is its own copy.
    if point and point ~= "" then
        Core.boarding[string.lower(script)] = point
    else
        Core.boarding[string.lower(script)] = nil
    end
end

function Bench:spawn()
    local entry = current()
    if not entry then
        return
    end
    -- Bound in an earlier session whose bindings were never saved: bind it
    -- again, so what the record says and what the registry does agree.
    local decided = session.bound[entry.script]
    if decided and decided.room and Core.rooms[decided.room] and not Core.bindings[BINDING_PREFIX .. entry.script] then
        sendBinding(entry.script, decided.room)
        if decided.boarding and decided.boarding ~= "" then
            sendBoarding(entry.script, decided.boarding)
        end
    end
    Core.admin("benchNext", {script = entry.script, radius = RADIUS})
    self:say(getText("IGUI_PhunInteriors_Bench_Spawning", entry.script))
end

Bench.onSpawn = Bench.spawn

function Bench:move(step)
    if #session.queue == 0 then
        return false
    end
    local pos = session.pos + step
    if pos < 1 or pos > #session.queue then
        self:say(getText("IGUI_PhunInteriors_Bench_End"))
        return false
    end
    session.pos = pos
    self:showCurrent()
    return true
end

function Bench:onPrev()
    if self:move(-1) then
        self:spawn()
    end
end

function Bench:onNext()
    if self:move(1) then
        self:spawn()
    end
end

function Bench:onBind()
    local entry = current()
    local roomId = self._roomCombo:getOptionData(self._roomCombo.selected)
    if not entry or not roomId then
        return
    end
    local boarding = self._boardingCombo:getOptionData(self._boardingCombo.selected) or ""
    sendBinding(entry.script, roomId)
    sendBoarding(entry.script, boarding)
    session.bound[entry.script] = {room = roomId, boarding = boarding}
    session.skipped[entry.script] = nil
    saveRecord()
end

function Bench:onUnbind()
    local entry = current()
    if not entry then
        return
    end
    if Core.bindings[BINDING_PREFIX .. entry.script] then
        Core.dispatch(Core.commands.editBinding, {binding = BINDING_PREFIX .. entry.script, remove = true})
    end
    sendBoarding(entry.script, "")
    session.bound[entry.script] = nil
    saveRecord()
    self:say(getText("IGUI_PhunInteriors_Bench_Unbound", entry.script))
end

function Bench:onSkip()
    local entry = current()
    if not entry then
        return
    end
    if not session.bound[entry.script] then
        session.skipped[entry.script] = true
        saveRecord()
    end
    self:onNext()
end

function Bench:onClear()
    Core.admin("benchClear", {radius = RADIUS})
end

function Bench:close()
    instance = nil
    self:removeFromUIManager()
    ISCollapsableWindowJoypad.close(self)
end

---------------------------------------------------------------------------
-- The single way in
---------------------------------------------------------------------------

function Bench.open(player)
    player = player or getPlayer()
    if not player then
        return nil
    end
    if instance then
        instance:setVisible(true)
        instance:bringToTop()
        return instance
    end
    loadRecord()
    local width = math.floor(560 * FONT_SCALE)
    instance = Bench:new(getCore():getScreenWidth() - width - 40, 120, width, 300, player)
    instance:initialise()
    instance:instantiate()
    instance:setTitle(getText("IGUI_PhunInteriors_Bench_Title"))
    instance:addToUIManager()
    return instance
end

function Bench.current()
    return instance
end

return Bench
