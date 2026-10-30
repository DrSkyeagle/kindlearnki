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
    -- Same inline style the plugin's controller applies, so the screenshot shows
    -- what the device will actually render.
    local Tokens = require("ui.tokens")
    local px = Tokens.body_font_px(Screen:getWidth(), Screen:getHeight())
    return string.format(
        '<div class="card card%s" style="font-size:%dpx;background-color:#fff;'
            .. 'color:#000;text-align:left;margin:0;padding:0;">%s</div>',
        tostring((item.card.ord or 0) + 1), px, html or "")
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

-- 2b. Deck pagination: more rows than the panel can hold must turn pages with
-- PagePress instead of dropping the overflow into an unreadable note.
local DeckView = require("ui.deckview")
local many = {}
for index = 1, 25 do
    many[index] = {
        id = index,
        name = string.format("牌组 %02d", index),
        depth = index % 2,
        counts = { new = 1, learning = 0, review = 0 },
    }
end
local decks_page = DeckView:new{
    decks = many,
    total = 25,
    date_text = "10月30日 周五",
    on_open = function() end,
    on_menu = function() end,
    on_sync = function() end,
}
decks_page:show()
logger.info(string.format("kindleanki-shot deck pages=%d rows_per_page=%d",
    decks_page.layout.page_count, decks_page.layout.rows_per_page))
assert(decks_page.layout.page_count >= 2, "deck list did not paginate")
shot("08-decks-page1")
decks_page:onPageForward()
assert(decks_page.layout.page == 2, "page forward did not advance")
shot("09-decks-page2")
decks_page:close()

-- 3. a long card: the PagePress rocker must page the body (the reason the
-- keys are not bound to "show answer" on these decks).
local all_cards = {}
for _, deck in ipairs(collection.decks) do
    for _, card in ipairs(collection:cards_in_decks({ deck.id })) do
        all_cards[#all_cards + 1] = card
    end
end
local longest, longest_len = nil, 0
for _, card in ipairs(all_cards) do
    local note = collection:note(card.nid)
    local total = 0
    for _, field in ipairs(note and note.fields or {}) do
        total = total + #field
    end
    if total > longest_len then
        longest, longest_len = card, total
    end
end
assert(longest, "no card found")

local long_note = collection:note(longest.nid)
local long_notetype = collection:notetype(long_note.mid)
local long_faces = Render.card_faces(long_notetype, long_note, longest, {})
local long_css = long_faces.css or long_notetype.css or ""
local long_html = string.format('<div class="card card%s">%s</div>',
    tostring((longest.ord or 0) + 1), long_faces.question_html)

local long_study = StudyView:new{
    face = { html = long_html, css = long_css },
    show_answer = false,
    progress = { done = 0, remaining = 1 },
    intervals = { "1m", "10m", "1d", "4d" },
    deck_name = item.context.deck_name,
    on_show_answer = function() end,
    on_rate = function() end,
    on_close = function() end,
}
long_study:show()
logger.info(string.format("kindleanki-shot longest real card chars=%d pages=%d",
    longest_len, tonumber(long_study.body_page_count) or 1))
shot("04-long-page1")

if (tonumber(long_study.body_page_count) or 1) <= 1 then
    -- The fixture has no card tall enough to paginate.  Prove the pager with a
    -- synthetic face rather than shipping a key binding nobody has exercised.
    local filler = {}
    for line = 1, 80 do
        filler[#filler + 1] = string.format(
            "<p>第 %d 行：这是一张用于验证翻页键的长卡片，按 PagePress 应该向下翻一页。</p>",
            line)
    end
    long_study:update_face({
        html = '<div class="card">' .. table.concat(filler) .. "</div>",
        css = long_css,
    }, false, { done = 0, remaining = 1 }, { "1m", "10m", "1d", "4d" })
    logger.info("kindleanki-shot synthetic long card pages="
        .. tostring(long_study.body_page_count))
    shot("04-long-page1")
end

local pages = tonumber(long_study.body_page_count) or 1
assert(pages >= 2, "long card did not paginate (pages=" .. tostring(pages) .. ")")

long_study:onPageForward()
logger.info("kindleanki-shot page-forward page=" .. tostring(long_study.body_page))
assert(long_study.body_page == 2, "forward paging did not reach page 2")
shot("05-long-page2")

long_study:onPageBackward()
logger.info("kindleanki-shot page-backward page=" .. tostring(long_study.body_page))
assert(long_study.body_page == 1, "backward paging did not return to page 1")

-- 4. login: now KOReader's own InputDialog (two steps), because a hand-built
-- InputText never received taps/keyboard on the device.  Check that the first
-- dialog appears with the keyboard, that "下一步" leads to the masked password
-- step, and that submitting hands the credentials over.
local Login = require("ui.login")
local submitted = nil
local email_dialog = Login.start{
    on_submit = function(email, password)
        submitted = { email = email, password = password }
    end,
}
shot("06-login-email")
assert(email_dialog and email_dialog.getInputText, "email dialog was not created")

email_dialog._input_widget:setText("tester@example.com")
email_dialog.buttons[1][2].callback() -- 下一步

local password_dialog = UIManager:getTopmostVisibleWidget()
assert(password_dialog and password_dialog.getInputText,
    "password dialog did not replace the email dialog")
assert(password_dialog.text_type == "password",
    "password dialog is not masked")
shot("07-login-password")

password_dialog._input_widget:setText("secret123")
password_dialog.buttons[1][2].callback() -- 登录
assert(submitted and submitted.email == "tester@example.com",
    "login did not pass the email through")
assert(submitted.password == "secret123", "login did not pass the password through")
logger.info("kindleanki-shot login submit ok (credentials not logged)")

logger.info("kindleanki-shot done")
os.exit(0)
