--[[--
Tap the first deck row and prove the study screen opens.

    COLLECTION=<collection.anki2> SHOT_DIR=/tmp/x \
      xvfb-run -a ./luajit harness/study_tap.lua

The device reported "tapping a deck does nothing"; the cause was a typo in the
card style helper, which only runs when a card is rendered.  This harness walks
the real path: DeckView zone -> on_open -> Controller.start_study -> card render.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"
local collection_path = assert(os.getenv("COLLECTION"), "COLLECTION is required")
local shot_dir = os.getenv("SHOT_DIR") or "/tmp"

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
if Device.init then Device:init() end
if Device.screen and Device.screen.init then Device.screen:init() end
require("document/canvascontext"):init(Device)

package.path = plugin_dir .. "/?.lua;" .. package.path

local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Model = require("model.collection")
local Controller = require("study.controller")

local collection = Model.open(collection_path)
local view = Controller.show_decks(collection)
assert(view, "deck view did not open")
UIManager:forceRePaint()

-- Pick a deck that actually has something due: earlier harness runs answer
-- cards, so the active deck can legitimately be empty, and an empty study
-- screen proves nothing about card layout.
local function row_with_cards()
    for _, candidate in ipairs(view.layout.rows) do
        if (tonumber(candidate.count_text) or 0) > 0 then
            return candidate
        end
    end
end

local row = row_with_cards()
while not row and (view.layout.page or 1) < (view.layout.page_count or 1) do
    view:onPageForward()
    UIManager:forceRePaint()
    row = row_with_cards()
end
row = row or view.layout.rows[1]
assert(row, "no deck rows laid out")
print("deck row:", tostring(row.deck_id), tostring(row.count_text))
local pos = Geom:new{ x = row.count_x - 40, y = row.row_top + math.floor(row.row_h / 2) }
view:onTapDeckList(nil, { pos = pos })
UIManager:forceRePaint()

local top = UIManager:getTopmostVisibleWidget()
assert(top and top.name == "kindleanki_studyview",
    "tapping the deck row did not open the study screen (top="
        .. tostring(top and top.name) .. ")")

local function shot(name)
    UIManager:setDirty(nil, "full")
    UIManager:forceRePaint()
    local path = shot_dir .. "/" .. name .. ".png"
    local ok, err = pcall(function()
        Device.screen:shot(path)
    end)
    assert(ok, "screenshot failed: " .. tostring(err))
    print("shot:", path)
end

-- Where the card really sits: the text area MuPDF owns, and its used bbox.
-- The screen is a title bar + ScrollHtmlWidget + button table, so a card that
-- starts in the top third of the text area is the layout working; a card that
-- starts near the middle (or has no bbox at all) is the old misalignment.
local function describe(view, label)
    local widget = view.scroll_widget and view.scroll_widget.htmlbox_widget
    if not widget or not widget.document then
        print(label .. " no document")
        return nil
    end
    local page = widget.document:openPage(1)
    local x0, y0, x1, y1 = page:getUsedBBox()
    page:close()
    print(string.format(
        "%s px=%d pages=%s text=%dx%d bbox=%.0f,%.0f,%.0f,%.0f answer=%s",
        label, require("ui.tokens").card_font_px(Device.screen:getWidth(),
            Device.screen:getHeight()),
        tostring(widget.page_count), widget.dimen.w, widget.dimen.h,
        x0, y0, x1, y1, tostring(view.show_answer)))
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1,
        w = widget.dimen.w, h = widget.dimen.h }
end

local first = describe(top, "CARD")
do
    -- Keep the exact HTML/CSS MuPDF was handed: the next layout bug will be
    -- diagnosed from these two files, not from a screenshot.
    local widget = top.scroll_widget
    local html_dump = assert(io.open(shot_dir .. "/face-front.html", "wb"))
    html_dump:write(tostring(widget and widget.html_body or ""))
    html_dump:close()
    local css_dump = assert(io.open(shot_dir .. "/face.css", "wb"))
    css_dump:write(tostring(widget and widget.css or ""))
    css_dump:close()
end
assert(first and first.y1 > first.y0, "the front has no visible content")
assert(first.y0 <= first.h * 0.4,
    string.format("front starts %.0f px down a %d px text area", first.y0, first.h))
assert(first.x1 <= first.w + 1,
    string.format("front is %0.f px wide, text area is %d", first.x1, first.w))

shot("10-study-from-deck")

-- Walk three cards the way the device does: show answer, rate, next card.
for round = 1, 3 do
    local view = UIManager:getTopmostVisibleWidget()
    if not view or view.name ~= "kindleanki_studyview" then
        print("cycle stop at round " .. round .. " (top="
            .. tostring(view and view.name) .. ")")
        break
    end
    describe(view, "FRONT " .. round)
    shot("cycle-" .. round .. "-front")
    view:_show_answer()
    UIManager:forceRePaint()
    describe(UIManager:getTopmostVisibleWidget(), "BACK " .. round)
    shot("cycle-" .. round .. "-answer")
    print("CYCLE state before rate answer=" .. tostring(view.show_answer))
    view:_rate(3)
    print("CYCLE state after rate answer=" .. tostring(view.show_answer))
    UIManager:forceRePaint()
end
print("CYCLE-DONE")
print("STUDY-TAP-OK")
os.exit(0)
