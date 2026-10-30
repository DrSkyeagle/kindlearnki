--[[--
Memory soak for the study screen: rate through many cards and watch RSS.

    COLLECTION=<collection.anki2> SOAK_N=40 \
      xvfb-run -a env SDL_VIDEODRIVER=x11 PLUGIN_DIR=... ./luajit harness/memory_soak.lua

The card body is a MuPDF document per face.  If a rebuild forgets to free it,
RSS climbs by megabytes per card -- on a 512 MB Voyage that is the difference
between "works" and "the device reboots after two cards".  This harness makes
that curve visible without a device.

Prints one line per card and a verdict: pass when RSS stays within
SOAK_GROWTH_MB (default 40) of the first card.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"
local collection_path = assert(os.getenv("COLLECTION"), "COLLECTION is required")
local rounds = tonumber(os.getenv("SOAK_N")) or 40
local growth_limit_mb = tonumber(os.getenv("SOAK_GROWTH_MB")) or 40

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

local UIManager = require("ui/uimanager")
local Tokens = require("ui.tokens")
local Collection = require("model.collection")
local DeckList = require("study.decklist")
local Session = require("study.session")
local Render = require("render.template")
local StudyView = require("ui.studyview")

local function rss_mb()
    local handle = io.open("/proc/self/status", "rb")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    local kb = tonumber(text:match("VmRSS:%s*(%d+)%s*kB"))
    return kb and (kb / 1024) or nil
end

local collection = Collection.open(collection_path)
local data = DeckList.build(collection)
local deck
for _, candidate in ipairs(data.decks) do
    local counts = candidate.counts or {}
    if (counts.new or 0) + (counts.learning or 0) + (counts.review or 0) > 0 then
        deck = candidate
        break
    end
end
assert(deck, "no deck with cards")

local session = Session.new{ collection = collection, deck_id = deck.id }
local item = session:next()
assert(item, "session is empty")

local function face(show_answer)
    if not item then
        return "<div class=\"card\">没有更多卡片</div>"
    end
    local faces = Render.card_faces(item.notetype, item.note, item.card, item.context)
    local html = show_answer and faces.answer_html or faces.question_html
    return string.format('<div class="card" style="%s">%s</div>',
        "background-color:#fff;color:#000;text-align:left;margin:0;padding:0;",
        Tokens.sanitize_html(html or ""))
end

local view = StudyView:new{
    face = { html = face(false), css = (item.notetype and item.notetype.css) or "" },
    show_answer = false,
    progress = session:progress(),
    intervals = item.intervals or {},
    deck_name = session:deck_name(),
    on_show_answer = function() end,
    on_rate = function() end,
    on_close = function() end,
}
view:show()
UIManager:forceRePaint()
local baseline = rss_mb() or 0
local peak = baseline

for round = 1, rounds do
    if not item then
        break
    end
    local answer = face(true)
    view:update_face({ html = answer, css = (item.notetype and item.notetype.css) or "" },
        true, session:progress(), item.intervals or {}, session:deck_name())
    UIManager:forceRePaint()

    session:answer(3)
    item = session:next()
    local next_css = (item and item.notetype and item.notetype.css) or ""
    local ok, err = pcall(function()
        view:update_face({ html = face(false), css = next_css },
            false, session:progress(), item and item.intervals or {},
            session:deck_name())
        UIManager:forceRePaint()
    end)
    if not ok then
        print("SOAK-ERROR round=" .. round .. ": " .. tostring(err))
        os.exit(1)
    end

    local rss = rss_mb() or 0
    if rss > peak then
        peak = rss
    end
    if round % 5 == 0 or round == 1 then
        print(string.format("SOAK round=%d rss=%.1fMB delta=%.1f pages=%s",
            round, rss, rss - baseline, tostring(view.body_page_count)))
    end
end

local final = rss_mb() or 0
print(string.format("SOAK-DONE rounds=%d baseline=%.1fMB peak=%.1fMB final=%.1fMB growth=%.1fMB",
    rounds, baseline, peak, final, final - baseline))
if final - baseline > growth_limit_mb then
    print("SOAK-FAIL growth above limit " .. growth_limit_mb .. " MB")
    os.exit(1)
end
print("SOAK-OK")
os.exit(0)
