--[[--
End-to-end check of the two zoom settings: the real StudyView, the real prefs
module, the real card.

    cd <koreader tree>
    COLLECTION=/path/to/collection.anki2 MEDIA_DIR=/tmp/knk-media \\
      SRC_PNG=/mnt/d/ankindle/out/probe-img.png SHOT_DIR=/tmp/zoom-ui \\
      xvfb-run -a env SDL_VIDEODRIVER=x11 \\
      PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \\
      ./luajit /mnt/d/ankindle/harness/zoom_ui_probe.lua

`zoom_probe.lua` answers "which CSS works"; this one answers "does the setting
reach the screen", so it goes through `core.prefs` exactly like the menu does.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"
local collection_path = os.getenv("COLLECTION")
local shot_dir = os.getenv("SHOT_DIR") or "/tmp/zoom-ui"
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
    logger.info("kindlearnki-zoom-ui", name, ok and "ok" or tostring(err), path)
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
local Prefs = require("core.prefs")

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
logger.info("kindlearnki-zoom-ui image=" .. image_name)

local face = Controller.face(item, { media_dir = media_dir })

-- A stand-in for the plugin's LuaSettings: `core.prefs` only needs these three
-- methods, and this way the probe proves the *setting* path, not just the CSS.
local function store_with(values)
    return {
        readSetting = function(_, key) return values[key] end,
        saveSetting = function() end,
        delSetting = function() end,
        flush = function() end,
    }
end

local CASES = {
    { name = "100-100", card_zoom = 100, image_zoom = 100 },
    { name = "150-100", card_zoom = 150, image_zoom = 100 },
    { name = "100-150", card_zoom = 100, image_zoom = 150 },
    { name = "100-50", card_zoom = 100, image_zoom = 50 },
    { name = "200-200", card_zoom = 200, image_zoom = 200 },
    { name = "50-50", card_zoom = 50, image_zoom = 50 },
}

for _, case in ipairs(CASES) do
    Prefs.attach(store_with{
        card_zoom = case.card_zoom,
        image_zoom = case.image_zoom,
        study_margin = 10,
    })
    for _, side in ipairs({ { suffix = "front", answer = false },
                            { suffix = "answer", answer = true } }) do
        local view = StudyView:new{
            face = face,
            show_answer = side.answer,
            progress = { done = 0, remaining = 1 },
            intervals = {},
            deck_name = target.deck.name,
            on_show_answer = function() end,
            on_rate = function() end,
            on_close = function() end,
        }
        view:show()
        shot("zoom-" .. case.name .. "-" .. side.suffix)
        view:close()
    end
end
Prefs.attach(nil)
logger.info("kindlearnki-zoom-ui done")
