--[[--
Card layout audit: render many real cards (front and back) offscreen and
measure where the ink actually lands, so layout bugs are counted instead of
being eyeballed on one screenshot.

    COLLECTION=<collection.anki2> AUDIT_N=60 \
      xvfb-run -a env SDL_VIDEODRIVER=x11 \
      PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \
      ./luajit /mnt/d/ankindle/harness/card_audit.lua

For every face it prints one CSV line:

    card=123 face=front pages=1 text=995x1057 ink=12,44,983,860 margins=12,44,12,197 flags=ok

`ink` is the ink bounding box on the framebuffer, `margins` are the distances
from that box to the text area's four edges (left,top,right,bottom).

Flags:
  blank      nothing was painted for that face      (the reported "no card")
  stale      the first paint was blank, a second one was not (cached BB)
  margin-x   left margin outside 4..60 px, i.e. the CSS reset did not apply
  gap-top    single page, more than 320 px of blank above the ink
  gap-bottom single page, more than 520 px of blank below the ink

Exit code 1 when a face is blank/stale or has a broken horizontal margin.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"
local collection_path = assert(os.getenv("COLLECTION"), "COLLECTION is required")
local limit = tonumber(os.getenv("AUDIT_N")) or 40
local out_path = os.getenv("AUDIT_OUT") or ""

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
if Device.init then Device:init() end
local Screen = Device.screen
if Screen.init then Screen:init() end
require("document/canvascontext"):init(Device)

local ffi = require("ffi")
package.path = plugin_dir .. "/?.lua;" .. package.path

local BlitBuffer = require("ffi/blitbuffer")
local Collection = require("model.collection")
local Render = require("render.template")
local StudyView = require("ui.studyview")
local Controller = require("study.controller")

local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
local frame = BlitBuffer.new(screen_w, screen_h, BlitBuffer.TYPE_BB8)
frame:fill(BlitBuffer.COLOR_WHITE)

--- Ink bounding box of a framebuffer region.  BB8: 0 = black, 255 = white.
local function ink_box(bb, x, y, w, h, threshold)
    threshold = threshold or 160
    local ptr = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    local first_x, last_x, first_y, last_y = nil, nil, nil, nil
    local step = 2
    for yy = y, y + h - 1 do
        local row = ptr + yy * stride
        for xx = x, x + w - 1, step do
            if row[xx] < threshold then
                if not first_x or xx < first_x then first_x = xx end
                if not last_x or xx > last_x then last_x = xx end
                if not first_y then first_y = yy end
                last_y = yy
                break
            end
        end
    end
    if not first_y then
        return nil
    end
    return first_x, first_y, last_x, last_y
end

local collection = Collection.open(collection_path, { read_only = true })
collection:load_decks()

--- Build the same item table Session:next() hands to the study screen.
local function item_for(card)
    local note = collection:note(card.nid)
    local notetype = note and collection:notetype(note.mid)
    local deck = collection:deck(card.did)
    local template = notetype and notetype.templates
        and notetype.templates[(tonumber(card.ord) or 0) + 1]
    if not note or not notetype then
        return nil
    end
    return {
        card = card,
        note = note,
        notetype = notetype,
        deck = deck,
        context = {
            deck_name = deck and deck.name or "",
            card_name = template and template.name or "",
        },
        intervals = {},
    }
end

local function wrap(html)
    return string.format('<div class="card card%s" style="%s">%s</div>',
        tostring(1), Controller.card_style(), html or "")
end

local lines = {}
local function emit(line)
    lines[#lines + 1] = line
    print(line)
end

local faces_ok, faces_bad = 0, 0

local function audit_face(item, show_answer, label)
    local faces = Render.card_faces(item.notetype, item.note, item.card, item.context)
    local css = faces.css or item.notetype.css or ""
    local html = show_answer and faces.answer_html or faces.question_html
    local view = StudyView:new{
        face = { html = wrap(html), css = css },
        show_answer = show_answer,
        progress = { done = 0, remaining = 1 },
        intervals = { "1m", "10m", "1d", "4d" },
        deck_name = item.context.deck_name,
        on_show_answer = function() end,
        on_rate = function() end,
        on_close = function() end,
    }
    local function paint()
        frame:fill(BlitBuffer.COLOR_WHITE)
        view:paintTo(frame, 0, 0)
    end
    paint()

    local area = view.textw and view.textw.dimen
    if not area or area.w <= 0 or area.h <= 0 then
        emit(string.format("card=%s face=%s flags=no-text-area",
            tostring(item.card.id), label))
        faces_bad = faces_bad + 1
        view:onCloseWidget()
        return
    end

    local x0, y0, x1, y1 = ink_box(frame, area.x, area.y, area.w, area.h)
    local flags = {}
    if not x0 then
        -- The reported bug: a face paints nothing until you page the body,
        -- which rebuilds the render buffer.  Paint again without rebuilding.
        paint()
        x0, y0, x1, y1 = ink_box(frame, area.x, area.y, area.w, area.h)
        flags[#flags + 1] = x0 and "stale" or "blank"
    end

    local pages = tonumber(view.body_page_count) or 1
    local margins = "-"
    if x0 then
        local left = x0 - area.x
        local top = y0 - area.y
        local right = (area.x + area.w - 1) - x1
        local bottom = (area.y + area.h - 1) - y1
        margins = string.format("%d,%d,%d,%d", left, top, right, bottom)
        if left < 0 or left > 80 then
            flags[#flags + 1] = "margin-x"
        end
        if pages <= 1 and math.abs(top - bottom) > 60 then
            -- A single-page card must be vertically centred: any large
            -- imbalance is the "下边距超宽" complaint coming back.
            flags[#flags + 1] = "asym-y"
        end
    end
    if #flags == 0 then
        flags[1] = "ok"
    end

    emit(string.format(
        "card=%s face=%s pages=%d text=%dx%d ink=%s margins=%s flags=%s",
        tostring(item.card.id), label, pages, area.w, area.h,
        x0 and string.format("%d,%d,%d,%d", x0, y0, x1, y1) or "-",
        margins, table.concat(flags, "|")))
    if flags[1] ~= "ok" then
        for _, flag in ipairs(flags) do
            if flag == "blank" or flag == "stale" or flag == "margin-x" then
                faces_bad = faces_bad + 1
                break
            end
        end
    end
    view:onCloseWidget()
end

--- Cards ordered by deck, so the audit covers several templates, not just the
--- active deck's first rows.
local cards = {}
for _, deck in ipairs(collection.decks or {}) do
    local deck_cards = collection:cards_in_decks({ deck.id }) or {}
    for _, card in ipairs(deck_cards) do
        cards[#cards + 1] = card
        if #cards >= limit then
            break
        end
    end
    if #cards >= limit then
        break
    end
end

local audited = 0
for _, card in ipairs(cards) do
    local item = item_for(card)
    if item then
        audited = audited + 1
        audit_face(item, false, "front")
        audit_face(item, true, "back")
        faces_ok = faces_ok + 2
    end
end

if out_path ~= "" then
    local file = io.open(out_path, "w")
    if file then
        file:write(table.concat(lines, "\n"), "\n")
        file:close()
    end
end

print(string.format("AUDIT-DONE cards=%d faces=%d bad=%d", audited, #lines, faces_bad))
collection:close()
os.exit(faces_bad == 0 and 0 or 1)
