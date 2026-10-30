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

local row = view.layout.rows[1]
assert(row, "no deck rows laid out")
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

-- Measure where the content really sits: our box, and MuPDF's used bbox.
do
    local box = top.layout and top.layout.body
    print(string.format("BOX x=%s y=%s w=%s h=%s", tostring(box and box.x),
        tostring(box and box.y), tostring(box and box.w), tostring(box and box.h)))
    local body = top.body
    if body and body.document then
        local page = body.document:openPage(1)
        local x0, y0, x1, y1 = page:getUsedBBox()
        page:close()
        print(string.format("BBOX %s %s %s %s (page w=%s h=%s)",
            tostring(x0), tostring(y0), tostring(x1), tostring(y1),
            tostring(body.dimen and body.dimen.w), tostring(body.dimen and body.dimen.h)))
    end
end

shot("10-study-from-deck")
print("STUDY-TAP-OK")
os.exit(0)
