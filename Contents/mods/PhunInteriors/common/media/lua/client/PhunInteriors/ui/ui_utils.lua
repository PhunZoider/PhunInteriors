if isServer() then
    return
end
require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- UI constants and the handful of widget helpers the vendored panels need.
--
-- A TRIMMED copy of PhunMart2's client/PhunMart_Client/ui/ui_utils.lua. That
-- file is 884 lines and most of it is PhunMart's own vocabulary -- offers,
-- price ladders, currency, traits, condition keys -- none of which means
-- anything here. What the two panels beside this file actually reach for is
-- four font constants and wrapText, so that is what came across, plus the
-- generic widget builders and the confirm dialog, which the editors use.
--
-- Vendored rather than depended on: this mod has no hard dependencies and is
-- not growing one for a UI helper. The duplication is deliberate and the cost
-- is knowing it is there -- a fix to PhunMart's copy has to be carried over by
-- hand.
--
-- FONT_SCALE is the whole reason these are constants rather than literals. PZ
-- lets a player pick a UI font size, so a panel laid out in pixels is right at
-- one setting and unreadable at the others; every size below is derived from
-- the measured height of the small font instead.
-- ---------------------------------------------------------------------------

local tools = {}
Core.ui.tools = tools

tools.FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
tools.FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
tools.FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
tools.BUTTON_HGT = tools.FONT_HGT_SMALL + 6
tools.FONT_SCALE = tools.FONT_HGT_SMALL / 14
tools.HEADER_HGT = tools.FONT_HGT_MEDIUM + 2 * 2
tools.BUTTON_WID = 100 * tools.FONT_SCALE

function tools.getLabel(text, x, y)
    local label = ISLabel:new(x, y, tools.FONT_HGT_SMALL, text, 1, 1, 1, 1, UIFont.Small, true);
    label:initialise();
    label:instantiate();
    return label;
end

function tools.getTextbox(value, tooltip, x, y, width)
    local textbox = ISTextEntryBox:new(value and tostring(value) or "", x, y, width or 200, tools.FONT_HGT_SMALL + 4);
    textbox:initialise();
    -- textbox:instantiate();
    if tooltip then
        textbox:setTooltip(tooltip)
    end
    textbox:setAnchorRight(true);
    return textbox;
end

function tools.getLabeledTextbox(label, tooltip, value, x, y, xOffset, boxWidth)
    local lbl = tools.getLabel(label, x, y)
    local text = tools.getTextbox(value, tooltip, x + (xOffset or 150), y, boxWidth)
    return lbl, text
end

function tools.getBool(txt, tooltip, x, y)

    local checkbox = ISTickBox:new(x, y, tools.BUTTON_HGT, tools.BUTTON_HGT, getTextOrNull(txt) or txt)
    checkbox:initialise();
    checkbox:instantiate();
    checkbox:addOption(getTextOrNull(txt) or txt, nil)
    checkbox:setSelected(1, true)
    checkbox:setWidthToFit()
    if tooltip then
        checkbox.tooltip = tooltip
    end
    return checkbox

end

function tools.getContainerPanel(x, y, w, h, fns)
    local panel = ISPanel:new(x, y, w, h);
    panel:initialise();
    panel:instantiate();
    panel:setAnchorRight(true);
    panel:setAnchorBottom(true);
    panel:setAnchorTop(true);
    panel:setAnchorLeft(true);
    panel:addScrollBars();
    panel.vscroll:setVisible(true)
    panel:setScrollChildren(true)
    panel.prerender = fns.prerender or panel.prerender;
    panel.render = fns.render or panel.render;
    panel.onMouseWheel = fns.onMouseWheel or panel.onMouseWheel;
    return panel;

end

function tools.getTabPanel(x, y, w, h, fns)
    local f = fns or {}
    local panel = ISTabPanel:new(x, y, w, h);
    panel:initialise();
    panel:instantiate();
    panel:setAnchorRight(true);
    panel:setAnchorBottom(true);
    panel:setAnchorTop(true);
    panel:setAnchorLeft(true);
    panel.prerender = f.prerender or panel.prerender;
    panel.render = f.render or panel.render;
    panel.onMouseWheel = f.onMouseWheel or panel.onMouseWheel;
    return panel;
end

function tools.getListbox(x, y, w, h, columns, fns)

    -- Below the header, which the caller measures from the top of the panel.
    local top = y + tools.HEADER_HGT
    local f = fns or {}

    local box = ISScrollingListBox:new(x, top, w, h);
    box:initialise();
    box:instantiate();
    box.doDrawItem = f.draw or box.doDrawItem;
    box.onMouseUp = f.click or box.onMouseUp;
    box.onRightMouseUp = f.rightClick or box.onRightMouseUp;
    box.itemheight = tools.FONT_HGT_SMALL + 6 * 2
    box.selected = 0;
    -- PhunMart's copy sets box.joypadParent = self here, and `self` is not a
    -- parameter of this function, so it resolves as a global and assigns nil.
    -- Dropped rather than carried: a line that has never done anything is
    -- worse than no line, because the next reader assumes it does something.
    box.font = UIFont.NewSmall;
    box:setAnchorRight(true);
    box:setAnchorBottom(true);
    box:setAnchorTop(true);
    box:setAnchorLeft(true);

    for i, v in ipairs(columns) do
        box:addColumn(v, (i - 1) * 200);
    end

    -- box.prerender = function()
    --     -- ISScrollingListBox.prerender(box);
    -- end

    return box;
end

-- ── Shared display helpers ──────────────────────────────────────────────────


function tools.truncate(text, maxWidth, font)
    if getTextManager():MeasureStringX(font, text) <= maxWidth then
        return text
    end
    local t = text
    while #t > 0 and getTextManager():MeasureStringX(font, t .. "...") > maxWidth do
        t = t:sub(1, -2)
    end
    return t .. "..."
end

-- Word-wrap text into lines fitting within maxWidth.
function tools.wrapText(text, maxWidth, font)
    local lines = {}
    local current = ""
    for word in text:gmatch("%S+") do
        local test = current == "" and word or (current .. " " .. word)
        if getTextManager():MeasureStringX(font, test) <= maxWidth then
            current = test
        else
            if current ~= "" then
                table.insert(lines, current)
            end
            current = word
        end
    end
    if current ~= "" then
        table.insert(lines, current)
    end
    return lines
end

function tools.confirm(text, onYes, owner)
    local lines = tools.wrapText(text, math.floor(340 * tools.FONT_SCALE), UIFont.Small)
    local w = math.floor(380 * tools.FONT_SCALE)
    local h = math.max(math.floor(130 * tools.FONT_SCALE),
        #lines * tools.FONT_HGT_SMALL + math.floor(90 * tools.FONT_SCALE))
    local modal = ISModalDialog:new((getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h,
        table.concat(lines, "\n"), true, owner, function(_, button)
            if button.internal == "YES" and onYes then
                onYes()
            end
        end)
    modal:initialise()
    modal:addToUIManager()
    return modal
end

--- A pairs loop, because PZ does not expose next(). See Core.tools.isEmpty,
--- which is the same function on the shared side; this copy exists so a client
--- UI file does not have to require the shared tools just to test a table.
function tools.isEmptyTable(t)
    if not t then
        return true
    end
    for _ in pairs(t) do
        return false
    end
    return true
end

return tools
