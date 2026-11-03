--[[--
Study screen (复习页): title bar + MuPDF text area + button table.

The layout is KOReader's own `TextViewer` layout, which is also how the
reference Kindlearnki reader (yizhixiaoheigou/kindle-anki v0.2.0) draws its
cards:

  ┌──────────────────────────────────────────────────────────────┐
  │ 古诗                                                     ×   │  <- TitleBar, × closes
  ├──────────────────────────────────────────────────────────────┤
  │                                                              │
  │   第 1 / 20 张                                               │  <- line 1
  │                                                              │
  │   卡片背面:                                                  │  <- line 2
  │                                                              │
  │   《江南》汉乐府                                             │  <- card HTML
  │   江南可采莲……                                               │
  │                                                              │
  ├───────────────────────┬──────────────────────────────────────┤
  │  重来 · 10 分钟       │  困难 · 1 天                         │  <- ratings
  ├───────────────────────┼──────────────────────────────────────┤
  │  记住 · 1 天          │  太简单 · 4 天                       │
  ├───────────────────────┴──────────────────────────────────────┤
  │                          退出                                │  <- tools
  └──────────────────────────────────────────────────────────────┘

Why this shape and not a hand-painted card box: the body is MuPDF, and MuPDF
reserves about 2em/3em of its own in-page margin.  Drawing our own box and
compensating for that margin is what broke the cards -- the compensation was
measured from the *previous* card, so fronts drifted or vanished outright.
Letting a ScrollHtmlWidget own the text area (top-aligned, paged by MuPDF
itself) makes every card start in the same place by construction, and long
cards page instead of shrinking.

The MuPDF document is freed on every rebuild: the study screen shows one card
at a time and a 512 MB Voyage cannot afford a document per revealed answer.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")

local Tokens = require("ui.tokens")
local PagePress = require("core.pagepress")

local Screen = Device.screen

-- Base stylesheet, prepended to the card's own (sanitised) stylesheet.  It
-- only pins what the reference cards pin: paper white, black ink, hard left,
-- no outer margin.  The card keeps whatever block spacing its template has.
local BASE_CSS = table.concat({
    "@page { margin: 0; }",
    "body { margin: 0; padding: 1em 0 0.4em 0;",
    "       background-color: #fff; color: #000;",
    "       text-align: left; line-height: 1.35; }",
    ".ka-meta { margin: 0 0 0.45em 0; color: #333; }",
    ".card { background-color: #fff; color: #000; text-align: left;",
    "        margin: 0; padding: 0; }",
}, string.char(10))

local function escape_html(text)
    return (tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

--- "10m" -> "10 分钟"; "1d" -> "1 天"; anything else is passed through.
local function humanize_interval(text)
    local value, unit = tostring(text or ""):match("^(%d+)([mhd])$")
    if not value then
        return tostring(text or "")
    end
    local names = { m = "分钟", h = "小时", d = "天" }
    return string.format("%s %s", value, names[unit])
end

--- Deck name from the collection: the separator is byte 0x1F and the title
--- bar only has room for the leaf, not the whole path.
local function deck_title(name)
    local printable = tostring(name or ""):gsub(string.char(31), "::")
    local leaf = printable:match("([^:]+)$")
    if leaf and leaf ~= "" then
        return leaf
    end
    return printable ~= "" and printable or Tokens.study_title
end

local StudyView = InputContainer:extend{
    name = "kindlearnki_studyview",
    covers_fullscreen = true,

    -- 当前面: { html = "...", answer_html = "...", css = "", text = <opt> }
    face = nil,
    show_answer = false,
    -- { done = 12, remaining = 55 }
    progress = nil,
    -- 4 next intervals for the rating buttons, e.g. { "1m", "10m", "25d", "4d" }
    intervals = nil,
    deck_name = "",

    on_show_answer = nil,
    on_rate = nil,    -- function(rating) with rating in 1..4
    on_close = nil,
}

--==========================================================================
-- Lifecycle
--==========================================================================

function StudyView:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.progress = self.progress or { done = 0, remaining = 0 }
    self.intervals = self.intervals or {}
    self.deck_name = tostring(self.deck_name or "")
    self.show_answer = self.show_answer and true or false

    self.body_page = 1
    self.body_page_count = 1
    self.scroll_widget = nil

    -- The rocker only reports while deviced has the fsr keypad switched on, and
    -- KOReader flips that switch itself only in its no-framework launch mode.
    -- Do it here as well, otherwise the buttons are dead whenever the stock
    -- framework is still running -- the bindings below are installed either way,
    -- there are just no events to deliver.
    PagePress.ensure()

    if Device.input then
        local group = Device.input.group or {}
        --[[ PagePress is the card's own pager, not the review flow.

        These decks contain cards several screens tall, and scrolling does not
        exist on e-ink, so the rocker has to page the *body*.  Showing the
        answer / rating stays on the buttons, which is also what the reference
        layout does.  PgBack is not "back" on a Voyage -- there is no Back key
        there -- so neither key is bound to Close; exiting is the title-bar ×. ]]
        self.key_events = {
            PageForward = { { group.PgFwd }, event = "PageForward" },
            PageBackward = { { group.PgBack }, event = "PageBackward" },
            Close = { { group.Back }, event = "Close" },
        }
    end

    self:_rebuild()
end

--- Refresh the visible card.
--
-- Signature is fixed by the plugin wiring: `(face, show_answer, progress,
-- intervals)`; the 5th argument `deck_name` is an optional extra so the title
-- bar can name the deck without a second call.
function StudyView:update_face(face, show_answer, progress, intervals, deck_name)
    self.face = face or self.face
    self.show_answer = show_answer and true or false
    if progress then
        self.progress = progress
    end
    if intervals then
        self.intervals = intervals
    end
    if deck_name ~= nil then
        self.deck_name = tostring(deck_name)
    end
    self:_rebuild()
    UIManager:setDirty(self, "ui")
    return self
end

function StudyView:show()
    UIManager:show(self)
    return self
end

--- Leave the screen: tell the caller first, then close ourselves.
function StudyView:close()
    if self.closed then
        return self
    end
    self.closed = true
    if type(self.on_close) == "function" then
        local ok, err = pcall(self.on_close)
        if not ok then
            logger.err("kindlearnki: study screen on_close failed:", err)
        end
    end
    UIManager:close(self)
    return self
end

--- Reached via the Back key or the Home key (InputContainer:onHome).
function StudyView:onClose()
    self:close()
    return true
end

function StudyView:onCloseWidget()
    self:_drop_scroll()
    self[1] = nil
end

--==========================================================================
-- Card HTML
--==========================================================================

--- @treturn string html body, @treturn string card stylesheet
function StudyView:_build_html(css)
    -- No "第 N / M 张" and no "卡片正面/背面" line above the card: the counter
    -- lives in the title bar, and the face is obvious from the buttons.  The
    -- saved band goes to the card text.
    local data = self.face or {}
    local html = self.show_answer and data.answer_html or data.html
    if type(html) ~= "string" or html == "" then
        html = type(data.html) == "string" and data.html or ""
    end
    if html == "" then
        local text = type(data.text) == "string" and data.text or ""
        if text ~= "" then
            html = '<div class="card">'
                .. escape_html(text):gsub(string.char(10), "<br/>") .. "</div>"
        else
            html = string.format('<div class="ka-meta">%s</div>',
                escape_html(Tokens.empty_text))
        end
    end

    -- Inline styles inside the card are sanitised too: notes often carry
    -- `text-align:center` / margin / background on their own tags, which the
    -- template-stylesheet stripper never sees.
    return Tokens.sanitize_html(html), (type(css) == "string" and css or "")
end

--==========================================================================
-- Buttons
--==========================================================================

--- Rating button label: "重来 10 分钟".  A space, not "·", keeps the four
--- cells of the single row comfortable on a 1072 px panel.
function StudyView:_rating_label(index)
    local label = Tokens.rating_labels[index] or tostring(index)
    local interval = humanize_interval(self.intervals and self.intervals[index])
    if interval ~= "" then
        return string.format("%s %s", label, interval)
    end
    return label
end

--- Counter shown in the title bar next to the deck name.
function StudyView:_title_text()
    local progress = self.progress or {}
    local done = math.max(0, math.floor(tonumber(progress.done) or 0))
    local remaining = math.max(0, math.floor(tonumber(progress.remaining) or 0))
    local total = done + remaining
    local name = deck_title(self.deck_name)
    if total <= 0 then
        return name
    end
    local position = math.min(done + 1, total)
    return string.format("%s    %s", name,
        string.format(Tokens.card_position_text, position, total))
end

function StudyView:_build_buttons()
    local progress = self.progress or {}
    local total = (tonumber(progress.done) or 0) + (tonumber(progress.remaining) or 0)
    if total <= 0 then
        -- Nothing due: 显示答案 / ratings would all be dead buttons.
        return {
            { { text = Tokens.exit_text, callback = function() self:close() end } },
        }
    end
    local rows = {}
    if self.show_answer then
        -- One row of four, as asked: the four ratings are the primary action
        -- and the intervals ride along in the same cell.
        local function rate(index)
            return function() self:_rate(Tokens.rating_values[index]) end
        end
        return { {
            { text = self:_rating_label(1), callback = rate(1) },
            { text = self:_rating_label(2), callback = rate(2) },
            { text = self:_rating_label(3), callback = rate(3) },
            { text = self:_rating_label(4), callback = rate(4) },
        } }
    end
    -- Front: one full-width bar, exactly like the reference card reader.  The
    -- way out is the title-bar ×, so no extra "exit" row eats a whole band.
    rows[1] = {
        { text = Tokens.action_text, callback = function() self:_show_answer() end },
    }
    return rows
end

--==========================================================================
-- Widget tree
--==========================================================================

--- Release the MuPDF document behind the text area.
function StudyView:_drop_scroll()
    local widget = self.scroll_widget
    if widget then
        local box = widget.htmlbox_widget
        if box and type(box.free) == "function" then
            pcall(box.free, box)
        end
    end
    self.scroll_widget = nil
end

--- Rebuild the screen for the current state.  Called once per state change
--- (open, reveal, next card), never from `paintTo`.
function StudyView:_rebuild()
    self:_drop_scroll()
    self[1] = nil

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    local data = self.face or {}
    local css = type(data.css) == "string" and data.css or ""
    -- Anki's stylesheet is written for the desktop web view: pinned px sizes,
    -- centered text and background images all fight the e-ink page.  Strip the
    -- parts that break layout, keep the parts that are typography.
    css = Tokens.strip_font_size(css)
    css = Tokens.strip_alignment(css)
    css = Tokens.strip_backgrounds(css)
    css = Tokens.tidy_declarations(css)

    local html = self:_build_html(css)

    -- The reference reader keeps the page wider than the text on both sides.
    -- With `@page { margin: 0 }` MuPDF no longer adds its own 2em inset, so the
    -- inset is ours to place: title bar, text and buttons share it.  It is the
    -- deck list's margin (`Tokens.space.margin`), so the two screens line up at
    -- the same left/right edge instead of the card sitting in a narrower column
    -- (0.3.5; the card used to carry a hardcoded 34).
    local inset = Screen:scaleBySize(Tokens.space.margin)
    local content_w = screen_w - 2 * inset
    if content_w < screen_w * 0.6 then
        content_w = math.floor(screen_w * 0.6)
    end

    self.titlebar = TitleBar:new{
        width = content_w,
        align = "left",
        with_bottom_line = true,
        -- Deck name plus "第 N / M 张" on one line.  No wrapping: a long name
        -- must not change the title bar height, or the text area would move
        -- between cards; TitleBar shrinks the font and then truncates.
        title = self:_title_text(),
        title_multilines = false,
        show_parent = self,
        close_callback = function() self:close() end,
    }

    self.button_table = ButtonTable:new{
        width = content_w - 2 * Size.padding.default,
        buttons = self:_build_buttons(),
        zero_sep = true,
        show_parent = self,
    }

    local text_h = screen_h - self.titlebar:getHeight() - self.button_table:getSize().h
    if text_h < Screen:scaleBySize(80) then
        text_h = Screen:scaleBySize(80)
    end

    local font_px = Tokens.card_font_px(screen_w, screen_h)
    self.scroll_widget = ScrollHtmlWidget:new{
        html_body = html,
        html_resource_directory = data.resource_dir,
        -- Template stylesheet first, our hard layout rules last: equal
        -- specificity means the later declaration wins, so a deck cannot move
        -- the card body with its own margins.
        css = BASE_CSS .. string.char(10) .. css
            .. string.char(10) .. Tokens.layout_override_css(),
        default_font_size = font_px,
        width = content_w,
        height = text_h,
        -- A hairline page indicator instead of KOReader's default 6-unit bar:
        -- on a paged e-ink card the bar is a reminder, not a drag target.
        scroll_bar_width = Screen:scaleBySize(2),
        text_scroll_span = Screen:scaleBySize(8),
        dialog = self,
        highlight_text_selection = true,
    }

    local box = self.scroll_widget.htmlbox_widget
    self.body_page = 1
    self.body_page_count = math.max(1, tonumber(box and box.page_count) or 1)

    self.textw = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.scroll_widget,
    }

    local buttons_h = self.button_table:getSize().h
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        VerticalGroup:new{
            align = "left",
            self.titlebar,
            self.textw,
            CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = buttons_h },
                self.button_table,
            },
        },
    }

    logger.info(string.format(
        "kindlearnki: card render px=%d pages=%d answer=%s",
        font_px, self.body_page_count, tostring(self.show_answer)))
end

function StudyView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
end

--==========================================================================
-- Actions
--==========================================================================

function StudyView:_show_answer()
    if type(self.on_show_answer) == "function" then
        local ok, err = pcall(self.on_show_answer)
        if not ok then
            logger.err("kindlearnki: study screen on_show_answer failed:", err)
        end
    end
end

function StudyView:_rate(rating)
    if type(self.on_rate) == "function" then
        local ok, err = pcall(self.on_rate, rating)
        if not ok then
            logger.err("kindlearnki: study screen on_rate failed:", err)
        end
    end
end

--==========================================================================
-- Body paging
--==========================================================================

--- Page an oversized card forward.  Returns false when it fits one screen.
function StudyView:next_body_page()
    if not self.scroll_widget then
        return false
    end
    if self.body_page >= self.body_page_count then
        return false
    end
    self.scroll_widget:scrollText(1)
    self.body_page = self.body_page + 1
    UIManager:setDirty(self, "ui")
    return true
end

--- Page an oversized card backward.  Returns false when already on page 1.
function StudyView:previous_body_page()
    if not self.scroll_widget then
        return false
    end
    if self.body_page <= 1 then
        return false
    end
    self.scroll_widget:scrollText(-1)
    self.body_page = self.body_page - 1
    UIManager:setDirty(self, "ui")
    return true
end

--- PagePress forward: next body page, or nothing when the card fits one page.
function StudyView:onPageForward()
    self:next_body_page()
    return true
end

--- PagePress backward: previous body page.
function StudyView:onPageBackward()
    self:previous_body_page()
    return true
end

return StudyView
