-- Wires session + renderer + screens together.
--
-- `main.lua` only calls into this module; the module owns the navigation
-- (deck list -> study -> back), so the plugin entry never has to know whether a
-- screen is a KOReader widget or something else.

local DeckList = require("study.decklist")
local Session = require("study.session")

local Controller = {}

local function require_gettext()
    local ok, translate = pcall(require, "gettext")
    if ok then
        return translate
    end
    return function(text)
        return text
    end
end

local _ = require_gettext()

--- Lazily require UI modules: none of them may be loaded in a headless host,
--- and a missing one must degrade to a message instead of killing the plugin.
local function load_ui(name)
    local ok, module = pcall(require, name)
    if not ok then
        return nil, module
    end
    return module
end

--- Show the deck list.
-- @tparam table opts { on_close = function() }
--- Inline style for the card body: paper white, black ink, hard left.
--
-- No `font-size` here on purpose.  The card is laid out by MuPDF through a
-- ScrollHtmlWidget, whose base font size is `Tokens.card_font_px()`; a pinned
-- px size would override that and, worse, multiply MuPDF's own 2em/3em page
-- margin by the same factor (that is what pushed fronts out of their box).
function Controller.card_style()
    return "background-color:#fff;color:#000;text-align:left;margin:0;padding:0;"
end

function Controller.show_decks(collection, opts)
    opts = opts or {}
    local DeckView, load_error = load_ui("ui.deckview")
    if not DeckView then
        return nil, tostring(load_error)
    end

    local data = DeckList.build(collection)
    local view
    view = DeckView:new{
        decks = data.decks,
        total = data.total,
        date_text = data.date_text,
        on_open = function(deck_id)
            Controller.start_study(collection, deck_id, view)
        end,
        on_menu = function()
            Controller.close(view)
            if opts.on_close then
                opts.on_close()
            end
        end,
        on_sync = opts.on_sync or function() end,
    }
    view:show()
    return view
end

function Controller.close(view)
    if view and type(view.close) == "function" then
        pcall(view.close, view)
    end
end

--- Start a study session for one deck (nil / 1 = all decks).
function Controller.start_study(collection, deck_id, parent_view)
    local StudyView, load_error = load_ui("ui.studyview")
    if not StudyView then
        return nil, tostring(load_error)
    end
    local Render = load_ui("render.template")

    local session = Session.new{
        collection = collection,
        deck_id = deck_id or collection:active_deck_id(),
    }

    local view
    local function current_face(item)
        if not item then
            return { html = "", css = "" }
        end
        if not Render then
            -- No renderer: show the first field so the session is still usable
            -- for testing the scheduler UI.
            local first = item.note and item.note.fields[1] or ""
            return { html = "<div>" .. first .. "</div>", css = "" }
        end

        local faces = Render.card_faces(item.notetype, item.note, item.card,
            item.context)
        local css = faces.css or (item.notetype and item.notetype.css) or ""

        -- The sanitizer strips class/id (it treats card content as hostile),
        -- but Anki's own CSS targets `.card` / `.cloze`.  Wrapping *after*
        -- sanitising gives the stylesheet its hooks without trusting the card.
        local function wrap(html, extra_class)
            local classes = "card"
            if extra_class then
                classes = classes .. " " .. extra_class
            end
            -- Inline styles win over the template's stylesheet in MuPDF; the
            -- appended `.card { … }` rule alone was not enough to override
            -- `text-align: center` and the tiny font baked into Anki's CSS.
            return string.format('<div class="%s" style="%s">%s</div>',
                classes, Controller.card_style(), html or "")
        end

        local card_class = "card" .. tostring((item.card.ord or 0) + 1)
        return {
            html = wrap(faces.question_html, card_class),
            answer_html = wrap(faces.answer_html, card_class),
            css = css,
            media = faces.media,
        }
    end

    local item = session:next()
    local face = current_face(item)
    -- The title bar names the deck on every face; without this the bar shows
    -- the generic "复习" even though the session knows where it is.
    local deck_label = session:deck_name()

    view = StudyView:new{
        face = face,
        show_answer = false,
        progress = session:progress(),
        intervals = item and item.intervals or {},
        deck_name = deck_label,
        on_show_answer = function()
            if not view then
                return
            end
            view:update_face({
                html = face.answer_html or face.html,
                css = face.css,
            }, true, session:progress(), item and item.intervals or {}, deck_label)
        end,
        on_rate = function(rating)
            if not item then
                return
            end
            session:answer(rating)
            item = session:next()
            face = current_face(item)
            if view then
                view:update_face(face, false, session:progress(),
                    item and item.intervals or {}, deck_label)
            end
        end,
        on_close = function()
            Controller.close(view)
            -- The deck list is still in the widget stack underneath; closing
            -- the study screen reveals it.  Re-showing it here would raise
            -- "already shown".
        end,
    }
    view:show()
    return view
end

--- Summary used by the sync screen / about box.
function Controller.summary(collection)
    local data = DeckList.build(collection)
    return string.format(_("牌组 %d 个 · 今日待学 %d"),
        #data.decks, data.total)
end

return Controller
