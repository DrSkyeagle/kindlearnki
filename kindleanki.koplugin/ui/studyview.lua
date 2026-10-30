--[[--
Study screen (复习页): one card face at a time.

Layout, as fixed by the design:

  牌组名 ........................................... 已 12 · 余 55  ×   <- × 是退出口
  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬···································                <- 2px 进度线

                    （当前面，垂直居中；超长内容分页或缩字号，不滚动）

  ██████████████ 显示答案 ██████████████                                <- 正面：通栏黑条
  ┌────────┬────────┬────────┬────────┐
  │  重来  │  困难  │  记住  │ 太简单 │                                <- 背面：4 等分评分列
  │  1m    │  10m   │  25d   │  4d    │
  └────────┴────────┴────────┴────────┘

Two details that are easy to get wrong on the device and are handled here:

  * The card body is an `HtmlBoxWidget` (MuPDF) reused across faces: the widget
    is created once, then `free()`d and re-`setContent()`ed when the card markup
    actually changes.  Without the `free()` the previous MuPDF document and its
    render buffer stay alive -- on a 512 MB Voyage that is a leak per card.
  * The action area has one height for both faces (front bar and back columns
    are the same band), so revealing the answer never re-lays-out the body: a
    `setContent()` re-parse per reveal would be the most expensive thing this
    screen does.

Requires KOReader; required lazily by the plugin.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Tokens = require("ui.tokens")
local Widgets = require("ui.widgets")

local Screen = Device.screen

--- Design units -> device pixels.  One definition, used by layout and paint, so
--- the two can never disagree about a rule's thickness.
local function px(units)
    return Screen:scaleBySize(units)
end

-- The page-turn keys answer "记住" (3) on the back face; AnkiDroid's middle
-- rating.  Named here so the keybinding and the rating column cannot drift.
local StudyView = InputContainer:extend{
    name = "kindleanki_studyview",
    covers_fullscreen = true,

    -- 当前面: { html = "...", css = "", text = <opt plain fallback>, resource_dir = <opt> }
    face = nil,
    show_answer = false,
    -- { done = 12, remaining = 55 }
    progress = nil,
    -- 4 next intervals for the rating buttons, e.g. { "1m", "10m", "25d", "4d" }
    intervals = nil,
    -- Optional (5th arg of update_face): the deck name of the meta row.
    deck_name = "",

    on_show_answer = nil,
    on_rate = nil,    -- function(rating) with rating in 1..4
    on_close = nil,
}

--==========================================================================
-- Lifecycle
--==========================================================================

--- Is the HTML renderer loadable?  Answered once: a host without MuPDF must
--- still show a readable card through the plain-text path.
local html_available
local function has_html_renderer()
    if html_available == nil then
        local ok, widget = pcall(require, "ui/widget/htmlboxwidget")
        html_available = ok and type(widget) == "table"
    end
    return html_available
end

function StudyView:init()
    Tokens.reset_face_cache()

    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.progress = self.progress or { done = 0, remaining = 0 }
    self.intervals = self.intervals or {}
    self.deck_name = tostring(self.deck_name or "")
    self.show_answer = self.show_answer and true or false

    -- Cached card body, see `_load_body`.
    self.body = nil
    self.body_mode = nil -- "html" | "text"
    self.body_key = nil  -- identifies what is currently rendered
    self.body_lines = nil
    self.body_face = nil
    self.body_page = 1
    self.body_page_count = 1

    if Device:isTouchDevice() then
        self.ges_events = {
            TapStudy = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
        }
    end

    if Device:hasKeys() and Device.input then
        local Input = Device.input
        --[[ PagePress is the card's own pager, not the review flow.

        These decks contain cards several screens tall, and scrolling does not
        exist on e-ink, so the rocker has to page the *body*.  Showing the
        answer / rating stays on the touch targets (the full-width bar and the
        four columns), which is also what the design specifies.  PgBack is not
        "back" on a Voyage -- there is no Back key there -- so neither key is
        bound to Close; exiting is the × hot zone. ]]
        self.key_events = {
            PageForward = { { Input.group.PgFwd }, event = "PageForward" },
            PageBackward = { { Input.group.PgBack }, event = "PageBackward" },
            Close = { { Input.group.Back }, event = "Close" },
        }
    end

    self:_layout()
    self:_load_body()
end

--- Refresh the visible card.
--
-- Signature is fixed by the plugin wiring: `(face, show_answer, progress,
-- intervals)`; the 5th argument `deck_name` is an optional extra so the meta
-- row can name the deck without a second call.
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
    self:_layout()
    self:_load_body() -- no-op when the card markup did not change
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
            logger.err("kindleanki: study screen on_close failed:", err)
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
    self:_drop_body()
    self.layout = nil
    self.face = nil
end

--==========================================================================
-- Card body
--==========================================================================

--- Release the cached card body (MuPDF document + render buffer).
function StudyView:_drop_body()
    if self.body and type(self.body.free) == "function" then
        pcall(self.body.free, self.body)
    end
    self.body = nil
    self.body_mode = nil
    self.body_key = nil
    self.body_lines = nil
    self.body_face = nil
    self.body_metrics = nil
    self.body_page = 1
    self.body_page_count = 1
    self.body_height = nil
end

--- Make the cached body match `self.face`.
--
-- Cheap to call on every `update_face()`: when the markup is unchanged this
-- returns immediately, so revealing the answer costs no HTML parsing at all.
function StudyView:_load_body()
    local box = self.layout and self.layout.body
    if not box or box.w <= 0 or box.h <= 0 then
        return
    end
    local data = self.face or {}
    local html = type(data.html) == "string" and data.html or ""
    local css = type(data.css) == "string" and data.css or ""

    if html ~= "" and has_html_renderer() then
        local key = table.concat({ html, css, tostring(data.resource_dir or "") }, "\1")
        if self.body_mode == "html" and self.body and self.body_key == key then
            return
        end
        if self:_load_html_body(html, css, data.resource_dir, key) then
            return
        end
    end

    local text = type(data.text) == "string" and data.text or Widgets.to_plain_text(html)
    local key = table.concat({ text, tostring(box.w), tostring(box.h) }, "\1")
    if self.body_mode == "text" and self.body_key == key then
        return
    end
    self:_load_text_body(text, key)
end

--- @treturn bool true when the HTML path worked
function StudyView:_load_html_body(html, css, resource_dir, key)
    local box = self.layout.body
    local ok, err = pcall(function()
        local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
        if not self.body or self.body_mode ~= "html" then
            self:_drop_body()
            self.body = HtmlBoxWidget:new{
                dimen = Geom:new{ w = box.w, h = box.h },
            }
            self.body_mode = "html"
        end
        local body = self.body
        body.dimen.w = box.w
        body.dimen.h = box.h
        -- `setContent()` replaces `self.document` without closing the old one,
        -- so the buffer must be released explicitly before a new card is laid
        -- out, otherwise every face leaks a MuPDF document.
        body:free()
        -- Size the card from the screen, and drop the template's pinned
        -- `font-size` so that size actually applies.
        local body_px = Tokens.body_font_px(Screen:getWidth(), Screen:getHeight())
        local card_css = Tokens.flush_margins_css() .. Tokens.strip_alignment(
            Tokens.strip_backgrounds(Tokens.strip_font_size(css)))
            .. string.char(10)
            .. string.format(".card{font-size:%dpx;background-color:#fff;color:#000;margin:0;padding:0;text-align:left;}", body_px)
        body:setContent(html, card_css, body_px, nil, nil, resource_dir)
        --[[ MuPDF lays HTML out with a fixed page margin measured in em (about
        2em horizontally, 3em vertically: 110/165 px at 55 px).  Neither a CSS
        reset nor an inline style removes it, so measure it once and re-layout
        the *same* document wider, then paint shifted.  Re-laying out is cheap;
        re-parsing would double the native peak that already made the device
        reboot. ]]
        self.body_shift_x = 0
        self.body_shift_y = 0
        if self.body_page_count <= 1 then
            pcall(function()
                local page = body.document:openPage(1)
                local x0, y0 = page:getUsedBBox()
                page:close()
                local margin = math.floor(tonumber(x0) or 0)
                local top = math.floor(tonumber(y0) or 0)
                if margin > 2 or top > 2 then
                    body.dimen.w = box.w + 2 * math.max(margin, 0)
                    body.document:layoutDocument(body.dimen.w, body.dimen.h, body_px)
                    body.page_count = body.document:getPages()
                    self.body_shift_x = -math.max(margin, 0)
                    self.body_shift_y = -math.max(top, 0)
                end
            end)
        end

        -- Native memory is the suspect for the device reboot after two cards;
        -- leaving a breadcrumb in the log makes the next crash readable.
        pcall(function()
            local status = io.open("/proc/self/status", "r")
            if status then
                local text = status:read("*a") or ""
                status:close()
                local rss = text:match("VmRSS:%s*(%d+)%s*kB")
                if rss then
                    logger.info(string.format("kindleanki: card render rss=%.1f MB px=%d",
                        tonumber(rss) / 1024, body_px))
                end
            end
        end)
    end)
    if not ok then
        logger.warn("kindleanki: cannot render card HTML, using plain text:", err)
        self:_drop_body()
        return false
    end
    self.body_key = key
    self.body_page = 1
    self.body_page_count = math.max(1, tonumber(self.body.page_count) or 1)

    --[[ A single page laid out for the full body box is mostly blank below the
    text.  The widget blits its whole `dimen`, so centring it by pushing it down
    (the obvious way to get 垂直居中) would paint past the bottom of the box.
    Instead, shrink the widget to the height its content actually uses.  The
    page was laid out for the taller box, so rendering only its top pixels loses
    nothing and needs no second parse. ]]
    if self.body_page_count <= 1 then
        local ok_height, single_height = pcall(function()
            return self.body:getSinglePageHeight()
        end)
        if ok_height and single_height and single_height > 0
            and single_height <= box.h then
            self.body.dimen.h = single_height
            pcall(self.body.freeBb, self.body)
            self.body_height = single_height
        end
    end
    return true
end

--- Fallback / plain-text body: self-drawn, shrink-to-fit, never overflows.
function StudyView:_load_text_body(text, key)
    self:_drop_body()
    local box = self.layout and self.layout.body
    if not box or type(text) ~= "string" then
        return
    end
    self.body_mode = "text"
    self.body_key = key

    -- Shrink the face until the whole card fits the body box; the design allows
    -- "分页或缩小字号", and for plain text shrinking is cheaper than paging.
    local candidates = { Tokens.font.body, 17, 14, 12, 10 }
    local chosen
    for _, units in ipairs(candidates) do
        local face = Tokens.face(units)
        if face then
            local metrics = Widgets.metrics(face, Tokens.line_height_extra)
            local lines = Widgets.wrap(face, text, box.w)
            chosen = { face = face, metrics = metrics, lines = lines, units = units }
            if #lines * math.max(metrics.h, 1) <= box.h then
                break
            end
        end
    end
    if not chosen then
        return
    end
    self.body_face = chosen.face
    self.body_metrics = chosen.metrics
    self.body_lines = chosen.lines
end

--- Page an oversized card forward.  Returns false when there is no next page.
function StudyView:next_body_page()
    if self.body_mode ~= "html" or not self.body then
        return false
    end
    if self.body_page >= self.body_page_count then
        return false
    end
    self.body_page = self.body_page + 1
    pcall(function()
        self.body:setPageNumber(self.body_page)
        -- HtmlBoxWidget caches the rendered page in `bb` and `_render()` bails
        -- out while that buffer exists; freeing it lets the next paint render
        -- the new page.
        self.body:freeBb()
    end)
    UIManager:setDirty(self, "ui")
    return true
end

--==========================================================================
-- Layout
--==========================================================================

--- Compute the grid once per state change; never from `paintTo`.
function StudyView:_layout()
    local width, height = self.dimen.w, self.dimen.h

    local margin = px(Tokens.space.margin)
    local gap = px(Tokens.space.gap)
    local content_x = margin
    local content_right = width - margin
    local content_w = content_right - content_x

    local faces = {
        meta = Tokens.face(Tokens.font.meta),
        deck = Tokens.face(Tokens.font.deck),
        action = Tokens.face(Tokens.font.action),
        rating = Tokens.face(Tokens.font.rating),
        interval = Tokens.face(Tokens.font.rating_interval),
        exit = Tokens.face(Tokens.font.exit),
    }

    local layout = {
        faces = faces,
        content_x = content_x,
        content_right = content_right,
        content_w = content_w,
        gap = gap,
        zones = {},
    }
    local zones = layout.zones
    local function add_zone(rect, action)
        if rect then
            zones[#zones + 1] = { rect = rect, action = action }
        end
    end

    --== 右上角：退出（≥44dp 热区）=====================================
    local hit = px(Tokens.size.exit_hit)
    local exit_rect = Widgets.box(content_right - hit, margin, hit, hit)
    layout.exit_rect = exit_rect
    add_zone(exit_rect, function() self:close() end)

    --== meta 行：左牌组名 / 右进度 ====================================
    local meta_metrics = Widgets.metrics(faces.meta)
    local meta_band_h = math.max(hit, meta_metrics.h)
    local meta_baseline = margin + math.floor((meta_band_h - meta_metrics.h) / 2)
        + meta_metrics.baseline
    layout.meta_baseline = meta_baseline
    local progress = self.progress or {}
    layout.progress_text = Tokens.progress_text(progress.done, progress.remaining)

    local progress_w = Widgets.text_width(faces.meta, layout.progress_text)
    local progress_right = exit_rect.x - gap
    layout.progress_x = progress_right - progress_w
    local name_max = layout.progress_x - gap - content_x
    layout.deck_name = Widgets.truncate(faces.deck, self.deck_name, name_max)

    -- Progress: solid ink for what is done, dotted for what is left.  Grey would
    -- be the obvious choice, but a 16-level panel turns it into a smudge next to
    -- the body text.
    local done = tonumber(progress.done) or 0
    local remaining = tonumber(progress.remaining) or 0
    if done < 0 then done = 0 end
    if remaining < 0 then remaining = 0 end
    local total = done + remaining
    layout.progress_fraction = total > 0 and (done / total) or 0
    local progress_y = margin + meta_band_h + math.floor(gap / 2)
    layout.progress_y = progress_y

    --== 正文区（垂直居中）=============================================
    local body_top = progress_y + Tokens.size.progress + gap
    -- One action band height for both faces: revealing the answer must not move
    -- the body box, or every reveal would need a fresh MuPDF layout.
    local action_h = px(Tokens.size.action_bar)
    local action_top = height - action_h
    layout.action = Widgets.box(0, action_top, width, action_h)
    layout.action_top = action_top
    -- 卡片区四边贴边：左右通栏、下沿到答案栏、上沿到进度行下方。
    layout.body = Widgets.box(0, body_top, width, action_top - body_top)
    if layout.body.h < 0 then
        layout.body.h = 0
    end
    add_zone(layout.body, function() self:_tap_body() end)

    --== 底部动作区 ====================================================
    if self.show_answer then
        -- 4 等分评分列：标签 + 下次间隔
        local column_w = math.floor(width / #Tokens.rating_labels)
        layout.columns = {}
        for index = 1, #Tokens.rating_labels do
            local column_x = (index - 1) * column_w
            -- The last column takes the rounding remainder, so the band is
            -- flush with the right edge (通栏) like the front bar.
            local this_w = index == #Tokens.rating_labels
                and (width - column_x) or column_w
            local rect = Widgets.box(column_x, action_top, this_w, action_h)
            layout.columns[index] = rect
            add_zone(rect, (function(rating)
                return function() self:_rate(rating) end
            end)(Tokens.rating_values[index]))
        end
    else
        -- 正面：通栏黑条
        add_zone(layout.action, function() self:_show_answer() end)
    end

    self.layout = layout
    return layout
end

--==========================================================================
-- Actions
--==========================================================================

function StudyView:_show_answer()
    if type(self.on_show_answer) == "function" then
        local ok, err = pcall(self.on_show_answer)
        if not ok then
            logger.err("kindleanki: study screen on_show_answer failed:", err)
        end
    end
end

function StudyView:_rate(rating)
    if type(self.on_rate) == "function" then
        local ok, err = pcall(self.on_rate, rating)
        if not ok then
            logger.err("kindleanki: study screen on_rate failed:", err)
        end
    end
end

--- Tap on the card body: page an oversized card, otherwise reveal (front only).
function StudyView:_tap_body()
    if self.body_page < self.body_page_count then
        self:next_body_page()
        return
    end
    if not self.show_answer then
        self:_show_answer()
    end
end

--- Page an oversized card backward.  Returns false when already on page 1.
function StudyView:previous_body_page()
    if self.body_mode ~= "html" or not self.body then
        return false
    end
    if self.body_page <= 1 then
        return false
    end
    self.body_page = self.body_page - 1
    pcall(function()
        self.body:setPageNumber(self.body_page)
        self.body:freeBb()
    end)
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

--==========================================================================
-- Painting
--==========================================================================

function StudyView:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local colors = Widgets.colors()
    Widgets.rect(bb, x, y, self.dimen.w, self.dimen.h, colors.paper)

    local layout = self.layout
    if not layout then
        return
    end
    local faces = layout.faces

    -- 正文先画，页眉/进度线/答案栏后画：卡片上移后仍不会盖住顶部信息。
    self:_paint_body(bb, x, y, colors)

    --== meta 行 =======================================================
    if layout.deck_name and layout.deck_name ~= "" then
        Widgets.draw(bb, x + layout.content_x, y + layout.meta_baseline,
            faces.deck, layout.deck_name, colors.ink,
            layout.progress_x - layout.gap - layout.content_x)
    end
    Widgets.draw(bb, x + layout.progress_x, y + layout.meta_baseline,
        faces.meta, layout.progress_text, colors.ink)
    local exit_rect = layout.exit_rect
    local exit_metrics = Widgets.metrics(faces.exit)
    Widgets.draw_centered(bb, x + exit_rect.x, exit_rect.w,
        y + exit_rect.y + math.floor((exit_rect.h - exit_metrics.h) / 2) + exit_metrics.baseline,
        faces.exit, Tokens.exit_text, colors.ink)

    --== 2px 进度线 ====================================================
    local progress_w = layout.content_w
    local done_w = math.floor(progress_w * layout.progress_fraction)
    if done_w > 0 then
        Widgets.rule(bb, x + layout.content_x, y + layout.progress_y,
            done_w, Tokens.size.progress, colors.ink)
    end
    if done_w < progress_w then
        Widgets.dotted_rule(bb, x + layout.content_x + done_w, y + layout.progress_y,
            progress_w - done_w, colors.ink,
            px(Tokens.size.dot), px(Tokens.size.dot_gap), Tokens.size.progress)
    end

    --== 正文 ==========================================================

    --== 底部动作区 ====================================================
    local action = layout.action
    if self.show_answer then
        Widgets.rule(bb, x + action.x, y + action.y, action.w,
            Tokens.size.progress, colors.ink)
        local rating_metrics = Widgets.metrics(faces.rating)
        local interval_metrics = Widgets.metrics(faces.interval)
        local line_gap = math.floor(layout.gap / 2)
        local block_h = rating_metrics.h + line_gap + interval_metrics.h
        local block_top = action.y + math.floor((action.h - block_h) / 2)
        for index, column in ipairs(layout.columns) do
            if index > 1 then
                -- 1px divider between two rating targets
                Widgets.rect(bb, x + column.x, y + action.y,
                    Tokens.size.hairline, action.h, colors.ink)
            end
            Widgets.draw_centered(bb, x + column.x, column.w,
                y + block_top + rating_metrics.baseline,
                faces.rating, Tokens.rating_labels[index], colors.ink)
            local interval = self.intervals and self.intervals[index]
            if interval and interval ~= "" then
                Widgets.draw_centered(bb, x + column.x, column.w,
                    y + block_top + rating_metrics.h + line_gap + interval_metrics.baseline,
                    faces.interval, tostring(interval), colors.ink)
            end
        end
    else
        -- 正面：通栏黑条，纸上白字
        Widgets.rect(bb, x + action.x, y + action.y, action.w, action.h, colors.ink)
        local action_metrics = Widgets.metrics(faces.action)
        Widgets.draw_centered(bb, x + action.x, action.w,
            y + action.y + math.floor((action.h - action_metrics.h) / 2) + action_metrics.baseline,
            faces.action, Tokens.action_text, colors.paper)
    end
end

--- Body painting: the HTML widget owns its own buffer, plain text is drawn here.
function StudyView:_paint_body(bb, x, y, colors)
    local box = self.layout.body
    if box.h <= 0 or box.w <= 0 then
        return
    end

    if self.body_mode == "html" and self.body then
        -- Single-page cards are optically centred (the widget was shrunk to its
        -- content in `_load_html_body`); multi-page ones start at the top of the
        -- box, like a page of a book.
        -- 贴顶：卡片从正文区上沿开始，不再垂直居中留出大片空白。
        local offset = 0
        local ok, err = pcall(self.body.paintTo, self.body, bb,
            x + box.x + (self.body_shift_x or 0), y + box.y + offset + (self.body_shift_y or 0))
        if not ok then
            logger.warn("kindleanki: card body paint failed:", err)
        end
        return
    end

    if self.body_mode == "text" and self.body_lines and self.body_face then
        local block = Widgets.block_metrics(self.body_face, self.body_lines,
            Tokens.line_height_extra)
        local line_height = block.line_height > 0 and block.line_height or 1
        local offset = math.max(0, math.floor((box.h - block.height) / 2))
        -- Clip instead of overflowing: the design forbids scrolling, so the tail
        -- of an absurdly long card is simply not drawn past the box.
        local visible = math.min(#self.body_lines, math.floor(box.h / line_height))
        for index = 1, visible do
            Widgets.draw(bb, x + box.x, y + box.y + offset + block.baselines[index],
                self.body_face, self.body_lines[index], colors.ink, box.w)
        end
    end
end

--==========================================================================
-- Input
--==========================================================================

--- Hit-test the tap against the zones built during layout.
-- Unknown taps are swallowed: this is a full-screen page.
function StudyView:onTapStudy(_, ges)
    local layout = self.layout
    if not layout or not ges or not ges.pos then
        return true
    end
    for _, zone in ipairs(layout.zones) do
        if zone.rect and zone.rect:contains(ges.pos) then
            if zone.action then
                zone.action()
            end
            return true
        end
    end
    return true
end

return StudyView

