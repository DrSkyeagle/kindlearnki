--[[--
Render the plugin's screens inside a real KOReader tree and save PNGs.

    cd <koreader tree>
    COLLECTION=/path/to/collection.anki2 SHOT_DIR=/tmp/shots \
      xvfb-run -a env SDL_VIDEODRIVER=x11 \
      PLUGIN_DIR=/mnt/d/ankindle/kindleanki.koplugin \
      ./luajit /mnt/d/ankindle/harness/ui_shot.lua

This is the L2 check: the unit tests prove the data and the maths, this proves
that the widgets lay out and paint on the real 1072x1448 framebuffer (and that
MuPDF renders the card HTML with the device's font stack).
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"
local collection_path = os.getenv("COLLECTION")
local shot_dir = os.getenv("SHOT_DIR") or "/tmp/kindleanki-shots"

require("setupkoenv")

local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
if Device.init then
    Device:init()
end
local Screen = Device.screen
if Screen.init then
    Screen:init()
end

-- reader.lua does this before anything requires `ui/font`; without it
-- fontlist calls CanvasContext:isKindle() on a table that has no device methods.
require("document/canvascontext"):init(Device)

local UIManager = require("ui/uimanager")
local logger = require("logger")

package.path = plugin_dir .. "/?.lua;" .. package.path

local function ensure_dir(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "directory" then
        os.execute("mkdir -p '" .. path .. "'")
    end
end

local function shot(name)
    UIManager:setDirty(nil, "full")
    UIManager:forceRePaint()
    local path = shot_dir .. "/" .. name .. ".png"
    local ok, err = pcall(function()
        Screen:shot(path)
    end)
    logger.info("kindleanki-shot", name, ok and "ok" or tostring(err), path)
end

ensure_dir(shot_dir)

assert(collection_path, "COLLECTION is required")
local Collection = require("model.collection")
local collection = Collection.open(collection_path, { read_only = true })

local DeckList = require("study.decklist")
local data = DeckList.build(collection)
logger.info(string.format("kindleanki-shot decks=%d total=%d", #data.decks,
    data.total))

-- 1. deck list
local DeckView = require("ui.deckview")
local deck_view
deck_view = DeckView:new{
    decks = data.decks,
    total = data.total,
    date_text = data.date_text,
    on_open = function() end,
    on_menu = function() end,
    on_sync = function() end,
}
deck_view:show()
shot("01-decks")

-- 2. study screen, front then back
local Session = require("study.session")
local Render = require("render.template")
local StudyView = require("ui.studyview")

local session = Session.new{
    collection = collection,
    deck_id = collection:active_deck_id(),
}
local item = session:next()
assert(item, "no card to show")

local faces = Render.card_faces(item.notetype, item.note, item.card, item.context)
local css = faces.css or item.notetype.css or ""
local function wrap(html)
    return string.format('<div class="card card%s">%s</div>',
        tostring((item.card.ord or 0) + 1), html or "")
end

local study_view
study_view = StudyView:new{
    face = { html = wrap(faces.question_html), css = css },
    show_answer = false,
    progress = session:progress(),
    intervals = item.intervals,
    deck_name = item.context.deck_name,
    on_show_answer = function()
        study_view:update_face(
            { html = wrap(faces.answer_html), css = css },
            true, session:progress(), item.intervals, item.context.deck_name)
    end,
    on_rate = function() end,
    on_close = function() end,
}
study_view:show()
shot("02-card-front")

study_view:update_face({ html = wrap(faces.answer_html), css = css }, true,
    session:progress(), item.intervals, item.context.deck_name)
shot("03-card-answer")

logger.info("kindleanki-shot done")
os.exit(0)
