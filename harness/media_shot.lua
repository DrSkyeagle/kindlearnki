--[[--
L2 proof that card images render when the media directory is handed over.

    cd <koreader tree>
    COLLECTION=/path/to/collection.anki2 MEDIA_DIR=/tmp/knk-media \
      SRC_PNG=/mnt/d/ankindle/docs/screenshots/decklist.png \
      xvfb-run -a env SDL_VIDEODRIVER=x11 \
      PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \
      ./luajit /mnt/d/ankindle/harness/media_shot.lua

It picks a card whose note references a picture, puts a real PNG under that
exact file name, and shoots the same card twice: once with the media directory
wired into `ScrollHtmlWidget` (the 0.3.1 fix) and once without it.  The second
shot is the control -- it must show MuPDF's `[image]` placeholder, which is what
the plugin looked like before the fix.  If the two shots are identical, the
resource directory is not reaching MuPDF.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"
local collection_path = os.getenv("COLLECTION")
local shot_dir = os.getenv("SHOT_DIR") or "/tmp/kindlearnki-media-shots"
local media_dir = os.getenv("MEDIA_DIR") or "/tmp/knk-media"
local src_png = os.getenv("SRC_PNG")

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
    logger.info("kindlearnki-media-shot", name, ok and "ok" or tostring(err), path)
    assert(ok, tostring(err))
end

local function copy(src, dst)
    local input = assert(io.open(src, "rb"), "cannot open " .. tostring(src))
    local data = input:read("*a")
    input:close()
    local output = assert(io.open(dst, "wb"), "cannot write " .. dst)
    output:write(data)
    output:close()
end

ensure_dir(shot_dir)
ensure_dir(media_dir)
assert(collection_path, "COLLECTION is required")

local Collection = require("model.collection")
local collection = Collection.open(collection_path, { read_only = true })
-- `decks` is filled lazily; without this the scan below walks an empty list
-- and the script dies on "no card with a local image" for a deck full of them.
collection:load_decks()
local Controller = require("study.controller")
local StudyView = require("ui.studyview")

-- Find a card whose front or back references a local image.
local target, image_name
for _, deck in ipairs(collection.decks) do
    for _, card in ipairs(collection:cards_in_decks({ deck.id })) do
        local note = collection:note(card.nid)
        if note then
            for _, field in ipairs(note.fields or {}) do
                local name = tostring(field):match('<img[^>]-src="([^"/:]+)"')
                if name then
                    target = { card = card, note = note, deck = deck }
                    image_name = name
                    break
                end
            end
        end
        if target then
            break
        end
    end
    if target then
        break
    end
end
assert(target, "no card with a local image in this collection")

local notetype = collection:notetype(target.note.mid)
local item = {
    notetype = notetype,
    note = target.note,
    card = target.card,
    context = { deck_name = target.deck.name, card_name = "Card" },
}

-- Give the card its file: a real PNG under the name the card asks for.
local media_path = media_dir .. "/" .. image_name
if not io.open(media_path, "rb") then
    assert(src_png, "SRC_PNG is required to fabricate " .. image_name)
    copy(src_png, media_path)
end
logger.info("kindlearnki-media-shot image=" .. image_name .. " dir=" .. media_dir)

local face = Controller.face(item, { media_dir = media_dir })
assert(face.resource_dir == media_dir, "the face carries no resource_dir")

local function show(face_table, name, show_answer)
    local view = StudyView:new{
        face = face_table,
        show_answer = show_answer and true or false,
        progress = { done = 0, remaining = 1 },
        intervals = {},
        deck_name = target.deck.name,
        on_show_answer = function() end,
        on_rate = function() end,
        on_close = function() end,
    }
    view:show()
    shot(name)
    view:close()
end

-- Which face carries the picture?  Most decks put the media in a field the
-- front template does not print, so both faces are shot and the pair is the
-- evidence, not a single frame.
local without_dir = {
    html = face.html,
    answer_html = face.answer_html,
    css = face.css,
}

-- 1. With the media directory: the picture itself.
show(face, "media-01-front-with-dir", false)
show(face, "media-02-answer-with-dir", true)

-- 2. Control: same card, same file on disk, no resource directory.  This is
--    what every card looked like before 0.3.1 -- MuPDF's `[image]` placeholder.
show(without_dir, "media-03-front-without-dir", false)
show(without_dir, "media-04-answer-without-dir", true)

logger.info("kindlearnki-media-shot done")
