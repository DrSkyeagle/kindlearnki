--[[--
Deck list screen (牌组页): the landing page of the plugin.

Layout, top to bottom, as fixed by the design:

  日期(kicker) ................. 同步 ×   <- 右上角是唯一退出口（Voyage 没有返回键）
  484                                     <- 82 总数（hero）
  新 12 · 学 3 · 复 55                     <- 新/学/复 拆分
  ─────────────────────────────────────    <- 1px 墨线
  机器学习 …………………………………………  27       <- 点线引导的牌组行（子牌组缩进 + 左侧竖线）
    深度学习 …… 5
  全部牌组一起复习 484 →                   <- 页脚
  菜单                                     <- 底部一行

The screen is drawn straight into the screen framebuffer: no child widgets, no
scroll views, no animations.  A repaint allocates nothing but the layout table,
and the layout table is rebuilt only when the deck data or the screen size
changes -- never from `paintTo`.

Callbacks (`on_open`, `on_menu`, `on_sync`) are invoked through pcall: a raising
callback must not leave the screen half painted, which is what KOReader would
otherwise report as one line in crash.log and a frozen page.

Requires KOReader (device/screen/fonts); it is required lazily by the plugin so
a headless host can still load `core/` and `sched/`.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local DeckList = require("study.decklist")
local Tokens = require("ui.tokens")
local Widgets = require("ui.widgets")

local Screen = Device.screen

local DeckView = InputContainer:extend{
    name = "kindlearnki_deckview",
    -- We paint every pixel, so UIManager must not waste a refresh on whatever
    -- sits below us.
    covers_fullscreen = true,

    -- Caller-provided data.  `decks` is already reduced to what the row needs:
    -- { id, name, depth, counts = { new, learning, review } }.
    decks = nil,
    total = 0,
    -- `{ new, learning, review }` for the whole library, straight from
    -- `DeckList.build`.  It is not derivable from `decks`: a parent row already
    -- counts its children, so summing the rows double-counts nested decks.
    total_counts = nil,
    date_text = "",
    page = 1,

    -- Callbacks.  `on_open(nil)` means "全部牌组".
    on_open = nil,
    on_menu = nil,
    on_sync = nil,
}

--==========================================================================
-- Lifecycle
--==========================================================================

function DeckView:init()
    -- Device geometry (DPI override, rotate) may have changed since the last
    -- screen was built; faces are cached per unscaled size, so drop them.
    Tokens.reset_face_cache()

    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.decks = self.decks or {}
    self.total = tonumber(self.total) or 0
    self.date_text = tostring(self.date_text or "")

    if Device:isTouchDevice() then
        -- One full-page tap zone with hit-testing inside the handler: a zone per
        -- row would need re-registering on every data refresh, and GestureRange
        -- ranges are static once registered.
        self.ges_events = {
            TapDeckList = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
        }
    end

    if Device:hasKeys() and Device.input then
        -- Voyage has no Back key; Kindles with a keyboard and the emulator do.
        -- A binding that never matches costs nothing.
        local group = Device.input.group or {}
        self.key_events = {
            Close = { { group.Back }, event = "Close" },
        }
        -- PagePress turns the deck list, like every other paged screen.
        if group.PgFwd and group.PgBack then
            self.key_events.PageForward = { { group.PgFwd }, event = "PageForward" }
            self.key_events.PageBackward = { { group.PgBack }, event = "PageBackward" }
        end
    end

    self:_layout()
end

--- Replace the data of an already shown screen (after a sync, say).
-- Rebuilds the layout and asks for one repaint; no widget is recreated.
function DeckView:update(decks, total, date_text, total_counts)
    self.decks = decks or {}
    self.total = tonumber(total) or 0
    if date_text ~= nil then
        self.date_text = tostring(date_text)
    end
    if total_counts ~= nil then
        self.total_counts = total_counts
    end
    self:_layout()
    UIManager:setDirty(self, "ui")
    return self
end

function DeckView:show()
    UIManager:show(self)
    return self
end

function DeckView:close()
    UIManager:close(self)
    return self
end

function DeckView:onClose()
    self:close()
    return true
end

function DeckView:onCloseWidget()
    -- Drop the layout and the caller's deck tables: a closed screen must not
    -- keep them alive, and a late repaint must not touch freed data.
    self.layout = nil
    self.decks = nil
end

--==========================================================================
-- Layout
--==========================================================================

local function fire(callback, ...)
    if type(callback) ~= "function" then
        return
    end
    local ok, err = pcall(callback, ...)
    if not ok then
        logger.err("kindlearnki: deck screen callback failed:", err)
    end
end

--- Compute every rectangle, baseline and string once.
-- Runs on init and on `update()`; never from `paintTo`.
function DeckView:_layout()
    local width, height = self.dimen.w, self.dimen.h
    local function px(units)
        return Screen:scaleBySize(units)
    end

    local margin = px(Tokens.space.margin)
    local gap = px(Tokens.space.gap)
    local indent = px(Tokens.space.indent)
    local content_x = margin
    local content_right = width - margin
    local content_w = content_right - content_x

    local faces = {
        kicker = Tokens.face(Tokens.font.kicker),
        total = Tokens.face(Tokens.font.total),
        meta = Tokens.face(Tokens.font.meta),
        deck = Tokens.face(Tokens.font.deck),
        deck_count = Tokens.face(Tokens.font.deck_count),
        footer = Tokens.face(Tokens.font.footer),
        note = Tokens.face(Tokens.font.note),
        exit = Tokens.face(Tokens.font.exit),
    }

    local layout = {
        faces = faces,
        margin = margin,
        content_x = content_x,
        content_right = content_right,
        content_w = content_w,
        gap = gap,
        -- Scaled once here so `paintTo` recomputes nothing but positions.
        indent = indent,
        dot_size = px(Tokens.size.dot),
        dot_gap = px(Tokens.size.dot_gap),
        hairline = Tokens.size.hairline,
        zones = {},
    }
    local zones = layout.zones

    local function add_zone(rect, action)
        if rect then
            zones[#zones + 1] = { rect = rect, action = action }
        end
    end

    --== 右上角：退出（视觉可小，热区 ≥ 44dp）============================
    local hit = px(Tokens.size.exit_hit)
    local exit_rect = Widgets.box(content_right - hit, margin, hit, hit)
    layout.exit_rect = exit_rect
    add_zone(exit_rect, function() self:close() end)

    --== 顶部 kicker 行：日期 / 同步 / 退出 ==============================
    local kicker_metrics = Widgets.metrics(faces.kicker)
    local kicker_band_h = math.max(hit, kicker_metrics.h)
    local kicker_top = margin
    local kicker_baseline = kicker_top
        + math.floor((kicker_band_h - kicker_metrics.h) / 2)
        + kicker_metrics.baseline
    layout.kicker_text = self.date_text
    layout.kicker_baseline = kicker_baseline

    -- 同步 sits left of the exit zone, right aligned; its zone is padded up to
    -- the 44dp minimum height so the label is not a pixel-hunt.
    local sync_text = Tokens.sync_text
    local sync_w = Widgets.text_width(faces.kicker, sync_text)
    local sync_right = exit_rect.x - gap
    local sync_pad = px(6)
    local sync_rect = Widgets.box(sync_right - sync_w - sync_pad, kicker_top,
        sync_w + 2 * sync_pad, kicker_band_h)
    layout.sync_text = sync_text
    layout.sync_baseline = kicker_baseline
    layout.sync_x = sync_right - sync_w
    add_zone(sync_rect, function() fire(self.on_sync) end)

    --== hero 总数 =====================================================
    local total_text = tostring(math.floor(self.total))
    -- A four digit total cannot be set at 82 units on this page width; step the
    -- size down rather than clip a number the user is meant to read at a glance.
    local total_face = faces.total
    for _, units in ipairs({ Tokens.font.total, 64, 48, 36 }) do
        local face = Tokens.face(units)
        if face then
            -- Keep the smallest attempt as the fallback: a total that still
            -- does not fit then overflows the least instead of the most.
            total_face = face
            if Widgets.text_width(face, total_text) <= content_w then
                break
            end
        end
    end
    layout.total_face = total_face
    layout.total_text = total_text
    local total_metrics = Widgets.metrics(total_face)
    local total_top = kicker_top + kicker_band_h + gap
    layout.total_baseline = total_top + total_metrics.baseline
    local total_bottom = total_top + total_metrics.h

    --== 新/学/复 拆分（全部牌组的合计）=================================
    local counts = DeckList.display_counts(self.decks, self.total_counts)
    local meta_metrics = Widgets.metrics(faces.meta)
    local counts_top = total_bottom + math.floor(gap / 2)
    layout.counts_text = Tokens.counts_text(counts)
    layout.counts_baseline = counts_top + meta_metrics.baseline

    --== 1px 墨线 ======================================================
    local rule_y = counts_top + meta_metrics.h + math.floor(gap / 2)
    layout.rule_y = rule_y

    --== 底部：菜单 行 + 页脚 =========================================
    local menu_metrics = Widgets.metrics(faces.deck)
    local menu_h = math.max(hit, menu_metrics.h + 2 * gap)
    local menu_top = height - margin - menu_h
    local menu_w = Widgets.text_width(faces.deck, Tokens.menu_text)
    local menu_rect = Widgets.box(content_x, menu_top,
        math.max(hit, menu_w + 2 * gap), menu_h)
    layout.menu_top = menu_top
    layout.menu_baseline = menu_top + math.floor((menu_h - menu_metrics.h) / 2)
        + menu_metrics.baseline
    add_zone(menu_rect, function() fire(self.on_menu) end)

    local footer_metrics = Widgets.metrics(faces.footer)
    local footer_h = math.max(hit, footer_metrics.h + gap)
    local footer_top = menu_top - gap - footer_h
    local footer_rect = Widgets.box(content_x, footer_top, content_w, footer_h)
    layout.footer_top = footer_top
    layout.footer_baseline = footer_top
        + math.floor((footer_h - footer_metrics.h) / 2)
        + footer_metrics.baseline
    layout.footer_text = Tokens.all_decks_text(self.total)
    local footer_text_w = Widgets.text_width(faces.footer, layout.footer_text)
    add_zone(Widgets.box(content_x, footer_top,
            math.min(content_w, footer_text_w + 2 * gap), footer_h),
        function() fire(self.on_open, nil) end)

    --== 牌组行 =======================================================
    local rows_top = rule_y + Tokens.size.hairline + gap
    local rows_bottom = footer_top - gap
    local rows_available = rows_bottom - rows_top
    layout.rows_top = rows_top
    layout.rows = {}

    local deck_count = #self.decks
    layout.empty_text = nil
    layout.page_count = 1
    layout.page = 1
    layout.rows_per_page = deck_count
    if deck_count == 0 then
        layout.empty_text = Tokens.empty_text
        layout.empty_baseline = rows_top
            + math.floor((rows_available - meta_metrics.h) / 2)
            + meta_metrics.baseline
    elseif rows_available > 0 then
        local row_min = px(Tokens.size.row_min)
        local row_max = px(Tokens.size.row_max)
        local per_page = deck_count
        local row_h = math.min(row_max, math.floor(rows_available / deck_count))
        if row_h < row_min then
            -- Too many decks for one page at a comfortable row height: keep the
            -- height and page instead (a 1072x1448 panel fits ~11 rows).
            row_h = row_min
            per_page = math.max(1, math.floor(rows_available / row_h))
        end
        layout.row_h = row_h
        layout.rows_per_page = per_page

        local page_count = math.ceil(deck_count / per_page)
        layout.page_count = page_count
        self.page = math.max(1, math.min(tonumber(self.page) or 1, page_count))
        layout.page = self.page

        local first = (self.page - 1) * per_page + 1
        local last = math.min(first + per_page - 1, deck_count)
        local deck_metrics = Widgets.metrics(faces.deck)
        for index = first, last do
            local deck = self.decks[index]
            local slot = index - first
            local row_top = rows_top + slot * row_h
            local row = {
                deck_id = deck.id,
                depth = tonumber(deck.depth) or 0,
                row_top = row_top,
                row_h = row_h,
                baseline = row_top + math.floor((row_h - deck_metrics.h) / 2)
                    + deck_metrics.baseline,
            }
            row.name_x = content_x + row.depth * indent
            local count_text = tostring(math.floor(Tokens.count_total(deck.counts) + 0.5))
            row.count_text = count_text
            local count_w = Widgets.text_width(faces.deck_count, count_text)
            row.count_x = content_right - count_w
            local name_max = row.count_x - gap * 2 - row.name_x
            -- Rows show the last path component; indentation carries the
            -- hierarchy, so "好文章::知乎好文章" reads as "知乎好文章" one level in.
            row.name = Widgets.truncate(faces.deck,
                tostring(deck.display_name or deck.name or ""), name_max)
            row.name_right = row.name_x + Widgets.text_width(faces.deck, row.name)
            layout.rows[#layout.rows + 1] = row
            add_zone(Widgets.box(content_x, row_top, content_w, row_h),
                function() fire(self.on_open, deck.id) end)
        end

        if page_count > 1 then
            local page_text = string.format("%d/%d", self.page, page_count)
            local page_w = Widgets.text_width(faces.deck_count, page_text)
            local page_pad = px(6)
            layout.page_text = page_text
            layout.page_x = content_right - page_w
            add_zone(Widgets.box(content_right - page_w - page_pad,
                    footer_top, page_w + 2 * page_pad, footer_h),
                function() self:onPageForward() end)
        end
    end

    self.layout = layout
    return layout
end

--- Turn the deck pages; PagePress and the on-screen counter both land here.
function DeckView:_turn_page(delta)
    local layout = self.layout
    if not layout or (layout.page_count or 1) <= 1 then
        return true
    end
    self.page = ((self.page - 1 + delta) % layout.page_count) + 1
    self:_layout()
    UIManager:setDirty(self, "ui")
    return true
end

function DeckView:onPageForward()
    return self:_turn_page(1)
end

function DeckView:onPageBackward()
    return self:_turn_page(-1)
end

--==========================================================================
-- Painting
--==========================================================================

function DeckView:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    local colors = Widgets.colors()
    Widgets.rect(bb, x, y, self.dimen.w, self.dimen.h, colors.paper)

    local layout = self.layout
    if not layout then
        return
    end
    local faces = layout.faces

    -- kicker / 同步 / 退出
    Widgets.draw(bb, x + layout.content_x, y + layout.kicker_baseline,
        faces.kicker, layout.kicker_text, colors.ink)
    Widgets.draw(bb, x + layout.sync_x, y + layout.sync_baseline,
        faces.kicker, layout.sync_text, colors.ink)
    local exit_rect = layout.exit_rect
    local exit_metrics = Widgets.metrics(faces.exit)
    Widgets.draw_centered(bb, x + exit_rect.x, exit_rect.w,
        y + exit_rect.y + math.floor((exit_rect.h - exit_metrics.h) / 2) + exit_metrics.baseline,
        faces.exit, Tokens.exit_text, colors.ink)

    -- hero 总数
    Widgets.draw(bb, x + layout.content_x, y + layout.total_baseline,
        layout.total_face, layout.total_text, colors.ink)

    -- 新/学/复
    Widgets.draw(bb, x + layout.content_x, y + layout.counts_baseline,
        faces.meta, layout.counts_text, colors.ink)

    -- 1px 墨线
    Widgets.rule(bb, x + layout.content_x, y + layout.rule_y,
        layout.content_w, Tokens.size.hairline, colors.ink)

    -- 牌组行
    if layout.empty_text then
        Widgets.draw(bb, x + layout.content_x, y + layout.empty_baseline,
            faces.meta, layout.empty_text, colors.ink)
    end
    local indent = layout.indent
    local dot_size = layout.dot_size
    for _, row in ipairs(layout.rows) do
        -- 子牌组左侧竖线：每层一根，逐行首尾相接看起来是连续的
        for level = 1, row.depth do
            local line_x = layout.content_x + math.floor((level - 0.5) * indent)
            Widgets.rect(bb, x + line_x, y + row.row_top,
                layout.hairline, row.row_h, colors.ink)
        end
        Widgets.draw(bb, x + row.name_x, y + row.baseline,
            faces.deck, row.name, colors.ink,
            row.count_x - layout.gap - row.name_x)
        -- 点线引导：名字与数字之间的留白用点线连起来，视线不用来回找
        local dots_x = row.name_right + layout.gap
        local dots_right = row.count_x - layout.gap
        if dots_right > dots_x then
            Widgets.dotted_rule(bb, x + dots_x,
                y + row.baseline - dot_size - math.floor(layout.gap / 3),
                dots_right - dots_x, colors.ink,
                dot_size, layout.dot_gap, dot_size)
        end
        Widgets.draw(bb, x + row.count_x, y + row.baseline,
            faces.deck_count, row.count_text, colors.ink)
    end
    if layout.hidden_text then
        Widgets.draw(bb, x + layout.content_x, y + layout.hidden_baseline,
            faces.note, layout.hidden_text, colors.ink)
    end

    -- 页脚：全部牌组一起复习 N →
    Widgets.draw(bb, x + layout.content_x, y + layout.footer_baseline,
        faces.footer, layout.footer_text, colors.ink,
        layout.content_w)

    if layout.page_text then
        Widgets.draw(bb, x + layout.page_x, y + layout.footer_baseline,
            faces.deck_count, layout.page_text, colors.ink)
    end

    -- 底部一行：菜单
    Widgets.draw(bb, x + layout.content_x, y + layout.menu_baseline,
        faces.deck, Tokens.menu_text, colors.ink)
end

--==========================================================================
-- Input
--==========================================================================

--- Hit-test the tap against the zones built during layout.
-- Unknown taps are swallowed: this is a full-screen page, nothing should leak
-- through to the widget underneath.
function DeckView:onTapDeckList(_, ges)
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

return DeckView
