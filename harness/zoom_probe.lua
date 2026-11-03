--[[--
Which CSS knob actually scales pictures and text inside MuPDF?

    cd <koreader tree>
    COLLECTION=/path/to/collection.anki2 MEDIA_DIR=/tmp/knk-media \
      SRC_PNG=/mnt/d/ankindle/out/probe-img.png SHOT_DIR=/tmp/zoom-shots \
      xvfb-run -a env SDL_VIDEODRIVER=x11 \
      PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \
      ./luajit /mnt/d/ankindle/harness/zoom_probe.lua

AnkiDroid scales the card with `body { zoom: x }` and pictures with
`img { zoom: x }` (cardviewer/CardAppearance.kt).  MuPDF's HTML engine is not a
browser, so this probe renders the same card once per candidate rule and the
screenshots are measured afterwards.  It exists so the plugin copies a rule that
is proven to work on the device instead of one that merely parses.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"
local collection_path = os.getenv("COLLECTION")
local shot_dir = os.getenv("SHOT_DIR") or "/tmp/zoom-shots"
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
    logger.info("kindlearnki-zoom-probe", name, ok and "ok" or tostring(err), path)
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
collection:load_decks()
local Controller = require("study.controller")
local StudyView = require("ui.studyview")

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

local media_path = media_dir .. "/" .. image_name
if not io.open(media_path, "rb") then
    assert(src_png, "SRC_PNG is required to fabricate " .. image_name)
    copy(src_png, media_path)
end
logger.info("kindlearnki-zoom-probe image=" .. image_name)

local face = Controller.face(item, { media_dir = media_dir })
assert(face.resource_dir == media_dir, "the face carries no resource_dir")

local VARIANTS = {
    { name = "17-wrap-px-600", wrap = 600 },
    { name = "18-wrap-px-900", wrap = 900 },
    { name = "19-wrap-px-300", wrap = 300 },
    { name = "20-plain" },
}

local function wrap_html(html, px)
    if not px then
        return html
    end
    local out = (html:gsub("<img", '<div class="kaw"><img') .. "</div>")
    return out
end

local only = os.getenv("ONLY")
for _, variant in ipairs(VARIANTS) do
  if not only or variant.name:find(only, 1, true) then
    local css = face.css
    if variant.wrap then
        css = css .. string.char(10) .. ".kaw img { width: " .. variant.wrap .. "px; }"
    end
    if variant.css then
        css = css .. string.char(10) .. variant.css
    end
    for _, side in ipairs({ { suffix = "front", answer = false },
                            { suffix = "answer", answer = true } }) do
        local view = StudyView:new{
            face = {
                html = wrap_html(face.html, variant.wrap),
                answer_html = wrap_html(face.answer_html, variant.wrap),
                css = css,
                resource_dir = face.resource_dir,
            },
            show_answer = side.answer,
            progress = { done = 0, remaining = 1 },
            intervals = {},
            deck_name = target.deck.name,
            on_show_answer = function() end,
            on_rate = function() end,
            on_close = function() end,
        }
        view:show()
        shot(variant.name .. "-" .. side.suffix)
        view:close()
    end
  end
end
