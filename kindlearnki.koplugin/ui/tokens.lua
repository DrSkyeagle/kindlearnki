--[[--
Design tokens for the plugin's self-drawn screens.

Everything in here comes from the approved design and is copied verbatim: the
deck screen, the study screen, the drawing helpers and `tests/test_tokens.lua`
all read this one table, so a stray literal in a paint routine cannot drift
away from the design without the test noticing.

The file has to stay loadable by a bare LuaJIT (`tests/run.lua`), so it must not
require KOReader at load time.  The only KOReader dependency -- `ui/font` -- is
resolved lazily inside `Tokens.face()` and kept behind a pcall: a host without a
font engine degrades to "draw no text" instead of taking the screen down.

Colours stay hex strings.  The screens translate them to BlitBuffer colours (see
`ui/widgets.lua`), because the token is a design statement ("ink is #111111"),
while the buffer colour is a device fact (a 16-level grey panel has no #111111).
]]

local Log = require("core.log")

local Tokens = {}

--==========================================================================
-- Colour
--==========================================================================

--- Two inks only.  Hierarchy is carried by size and rules, not by greys: on a
--- 16-level e-ink panel a #666666 caption turns into mush next to the body text.
Tokens.color = {
    paper = "#FFFFFF", -- 背景纯白
    ink = "#111111",   -- 正文墨色
}

--==========================================================================
-- Type
--==========================================================================

--- Sizes are unscaled design units; the screens pass them through
--- `Screen:scaleBySize()`, so the design holds on a 300 dpi Voyage and on the
--- SDL emulator alike.
Tokens.font = {
    -- Body copy: the design's one typographic anchor.
    body = 20,
    -- Serif body face.  KOReader's `tfont` alias is NotoSans-*Bold* in this
    -- release (the serif line in ui/font.lua is commented out), so asking for
    -- it would give the "paper" design a heavy sans body.  Use the bundled
    -- Noto Serif by file name instead: Font:getFace() accepts a raw file name
    -- and falls back to `cfont` below when a build does not ship it.
    family = "NotoSerif-Regular.ttf",
    fallback = "cfont",
    -- 1.65 line pitch, i.e. the 0.65 extra line height a TextBoxWidget wants.
    line_height = 1.65,
    line_height_extra = 0.65,

    -- Derived sizes.  Kept next to the body size so the scale of the page is
    -- readable in one glance: 82 (hero) > 20 (body) > 16 (footer) > 14 (meta).
    kicker = 14,          -- 日期 / 右上角动作
    meta = 14,            -- 进度、新学分项说明
    deck = 20,            -- 牌组名字
    deck_count = 15,      -- 牌组右侧数字
    total = 82,           -- 顶部总数
    footer = 16,          -- 全部牌组一起复习
    action = 20,          -- 显示答案
    rating = 18,          -- 评分标签
    rating_interval = 14, -- 评分下方间隔
    note = 14,            -- 截断提示
    exit = 18,            -- 退出 ×（视觉可小，热区见 Tokens.size.exit_hit）
}

-- The interface promises this name at the top level; keep the two in sync.
Tokens.line_height_extra = Tokens.font.line_height_extra

--==========================================================================
-- Space
--==========================================================================

Tokens.space = {
    -- 10 是视觉边距：换行、文字与屏幕边缘的距离都用它。边缘手势误触时只把
    -- 触摸热区向内缩（见 `Tokens.size.exit_hit` 与各屏的 hit 计算），视觉
    -- 边距本身不变。
    margin = 10,
    -- Rhythm between the stacked blocks of a screen.
    gap = 8,
    -- Indent per deck depth level (child decks + the vertical guide line).
    indent = 16,
}

--==========================================================================
-- Size
--==========================================================================

--- Two kinds of number live here, and the screens never mix them up:
---   * line thicknesses are PHYSICAL pixels (a "1px 墨线" is one pixel of the
---     panel, not one design unit scaled up to two),
---   * everything else is an unscaled design unit and goes through
---     `Screen:scaleBySize()` (a 44dp touch target, a 64 unit action bar).
Tokens.size = {
    hairline = 1,     -- 物理像素：1px 墨线
    progress = 2,     -- 物理像素：复习页 2px 进度线
    dot = 1,          -- 设计单位：点线点径
    dot_gap = 6,      -- 设计单位：点线点距
    exit_hit = 44,    -- 设计单位（=dp）：退出热区最小边；Voyage 无返回键，这是唯一退出口
    action_bar = 64,  -- 设计单位：正面黑条 / 背面评分列，同一高度保证换面时正文区不跳动
    footer = 48,      -- 设计单位：全部牌组一起复习
    menu = 44,        -- 设计单位：底部 菜单 行
    row_min = 30,     -- 设计单位：牌组行高下限
    row_max = 64,     -- 设计单位：牌组行高上限
}

--==========================================================================
-- Copy
--==========================================================================

--- Fixed four-button rating scale, in AnkiDroid 2.16.5 order: 1 重来, 2 困难,
--- 3 记住, 4 太简单.  The labels are deliberately not translatable strings: the
--- plugin is Chinese-only and `tests/test_tokens.lua` locks these very bytes.
Tokens.rating_labels = { "重来", "困难", "记住", "太简单" }
Tokens.rating_values = { 1, 2, 3, 4 }

Tokens.action_text = "显示答案"
Tokens.menu_text = "菜单"
Tokens.sync_text = "同步"
Tokens.exit_text = "×"
Tokens.empty_text = "没有到期的卡片"
Tokens.all_decks_prefix = "全部牌组一起复习"

-- 复习页标题栏的计数。 参考实现把 "第 N / M 张" 单独占一行、再一行写
-- "卡片正面/背面"；这里两项都精简掉了：计数并进标题栏，正/背面由按钮区分。
Tokens.study_title = "复习"
Tokens.card_position_text = "第 %d / %d 张"

--- `已 N · 余 M` -- never `N/M`, which reads as a fraction of the whole deck.
-- @int done
-- @int remaining
-- @treturn string
function Tokens.progress_text(done, remaining)
    return string.format("已 %d · 余 %d", math.floor(tonumber(done) or 0),
                                          math.floor(tonumber(remaining) or 0))
end

--- `全部牌组一起复习 484 →`
-- @int total
-- @treturn string
function Tokens.all_decks_text(total)
    return string.format("%s %d →", Tokens.all_decks_prefix,
                         math.floor(tonumber(total) or 0))
end

--- `新 12 · 学 3 · 复 55`
-- @tparam table counts `{ new = 12, learning = 3, review = 55 }`
-- @treturn string
function Tokens.counts_text(counts)
    counts = counts or {}
    return string.format("新 %d · 学 %d · 复 %d",
        math.floor(tonumber(counts.new) or 0),
        math.floor(tonumber(counts.learning) or 0),
        math.floor(tonumber(counts.review) or 0))
end

--- How many cards a deck row has to answer for.
-- @tparam table counts
-- @treturn int
function Tokens.count_total(counts)
    counts = counts or {}
    return (tonumber(counts.new) or 0)
         + (tonumber(counts.learning) or 0)
         + (tonumber(counts.review) or 0)
end

--- What the deck list shows when not every deck fits on one page.
-- @int hidden
-- @treturn string
function Tokens.hidden_decks_text(hidden)
    return string.format("另有 %d 个牌组", math.floor(tonumber(hidden) or 0))
end

--==========================================================================
-- Helpers
--==========================================================================

--- Split `#RRGGBB` into 0..255 components.  Pure Lua so the tests can lock the
--- colour tokens without a frame buffer.
-- @string hex
-- @treturn int r
-- @treturn int g
-- @treturn int b
function Tokens.hex_to_rgb(hex)
    local r, g, b
    if type(hex) == "string" then
        r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    end
    if not r then
        -- A malformed token must not crash a repaint; callers get black ink,
        -- which is the safe side on a white page.
        return 0x11, 0x11, 0x11
    end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- Faces are resolved per size and cached: KOReader's `Font:getFace()` already
-- caches by (family, size), but the cache here also remembers the *fallback*
-- decision and keeps the warning to one line per size instead of one per repaint.
local face_cache = {}
local face_warned = {}

--- Forget cached faces.  Call it when the device geometry changed underneath us
--- (DPI override, rotate), which is also why the screens call it in `init()`.
function Tokens.reset_face_cache()
    face_cache = {}
    face_warned = {}
end

local function default_log(message)
    Log.warn(message)
end

--- Resolve the serif body face at `size` unscaled design units.
--
-- The serif chain is `tfont -> cfont`, each step attempted with pcall: a build
-- without the serif family (or without any font engine at all) must leave the
-- screen readable in the sans face rather than fail in the middle of a paint.
--
-- @int size
-- @tparam[opt] table options `require_fn` / `log_fn` injections for the tests
-- @treturn table|nil face
function Tokens.face(size, options)
    size = tonumber(size) or Tokens.font.body
    local injected = options ~= nil
    if not injected and face_cache[size] ~= nil then
        return face_cache[size] or nil
    end
    options = options or {}

    local req = options.require_fn or require
    local log = options.log_fn or default_log
    local function note(message)
        if injected or not face_warned[size] then
            face_warned[size] = true
            log(message)
        end
    end

    local face
    local ok_font, Font = pcall(req, "ui/font")
    if not ok_font or type(Font) ~= "table" or type(Font.getFace) ~= "function" then
        note(string.format("ui/font unavailable, no %s face at size %d",
            Tokens.font.family, size))
        face = false
    else
        local ok_primary, primary = pcall(Font.getFace, Font, Tokens.font.family, size)
        if ok_primary and primary then
            face = primary
        else
            note(string.format("serif face %q failed at size %d (%s); falling back to %q",
                Tokens.font.family, size, tostring(primary), Tokens.font.fallback))
            local ok_fallback, fallback = pcall(Font.getFace, Font, Tokens.font.fallback, size)
            if ok_fallback and fallback then
                face = fallback
            else
                note(string.format("fallback face %q also failed at size %d (%s); text will be skipped",
                    Tokens.font.fallback, size, tostring(fallback)))
                face = false
            end
        end
    end

    if not injected then
        face_cache[size] = face
    end
    return face or nil
end

--- Adaptive body font size for card text, in device pixels.
--
-- Anki templates almost always pin `.card { font-size: 20px; }`, which is tiny
-- on a 1072x1448 panel.  The size is derived from the screen instead of a fixed
-- number: roughly 26 CJK glyphs per line and 34 lines per page, clamped so it
-- stays readable on small emulator windows and does not explode on large ones.
function Tokens.body_font_px(width, height)
    width = tonumber(width) or 1072
    height = tonumber(height) or 1448
    -- 6% of the panel width lands on 64 px for a 1072-wide Voyage panel and
    -- still scales down for the 708-wide emulator window.
    local by_width = math.floor(width * 0.052)
    local by_height = math.floor(height / 22)
    local px = math.min(by_width, by_height)
    if px < 24 then
        px = 24
    elseif px > 64 then
        px = 64
    end
    return px
end

--- Body font size for the TitleBar/TextViewer card layout, in device pixels.
--
-- This layout leaves MuPDF in charge of the body: it reserves about 2em of
-- horizontal margin for itself, so the size is a page-typography number rather
-- than a "fill the panel" number.  38 px on a 1072-wide Voyage leaves ~24 CJK
-- glyphs per line inside the reserved margin, which is the density the
-- reference reader has.
function Tokens.card_font_px(width, height)
    width = tonumber(width) or 1072
    height = tonumber(height) or 1448
    local px = math.floor(width * 0.036)
    if px < 22 then
        px = 22
    elseif px > 48 then
        px = 48
    end
    return px
end

--- Drop painted backgrounds so the card sits on the panel's own paper.
--
-- Anki decks often carry ruled/grey/photo backgrounds; on a 16-level e-ink
-- panel they turn into dithering and swallow the text.  Text colour is kept so
-- intentional emphasis survives.
--
-- Everything is removed, including `url(...)` paints: the media files are not
-- on the device, and MuPDF turns a missing url() into a broken-image box that
-- shifts the whole card.  The url() form is matched first because a `data:`
-- URI contains `;` inside the parentheses.
local function strip_declaration(css, property_pattern)
    local pattern = "([;{]%s*)" .. property_pattern .. "%s*:%s*[^;{}]*;?"
    return (css:gsub(pattern, "%1"))
end

function Tokens.strip_backgrounds(css)
    css = tostring(css or "")
    css = css:gsub("([;{]%s*)background[%a%-]*%s*:%s*[^;{}]-url%([^%)]*%)[^;{}]*;?", "%1")
    local properties = {
        "background%-image",
        "background%-color",
        "background%-repeat",
        "background%-position",
        "background%-size",
        "background%-attachment",
        "background",
        "box%-shadow",
    }
    for _, property in ipairs(properties) do
        css = strip_declaration(css, property)
    end
    return css
end

--- Remove centring so the card starts at the panel's left edge.
--
-- MuPDF keeps applying the template's `.card { text-align: center }` even when
-- the wrapper carries an inline left alignment, so the declaration is removed.
-- `!important` is swallowed with it: leaving the keyword behind is a CSS syntax
-- error, and those are the cards whose margins came out different.
function Tokens.strip_alignment(css)
    return (tostring(css or ""):gsub("([;{]%s*)text%-align%s*:%s*[^;{}]*;?", "%1"))
end

--- Kill the default block margins MuPDF adds (h1/h2/p/body), which produced a
--- large blank band above the text.
function Tokens.flush_margins_css()
    return "body,h1,h2,h3,h4,h5,h6,p,ul,ol,li,blockquote,pre,div,table"
        .. "{margin:0;padding:0;}"
end

--- Hard layout rules, appended *after* the template stylesheet.
--
-- Equal specificity + later declaration wins, so a deck that pins its own
-- `.card { margin/padding/width }` can no longer move the text; the base
-- stylesheet alone was prepended and therefore always lost that fight.
--
-- `body` is deliberately left with its padding intact: the page inset of the
-- study screen lives there (see BASE_CSS in ui/studyview.lua).  Only the
-- margins are zeroed.
function Tokens.layout_override_css()
    return table.concat({
        "html, body { margin: 0; background: transparent; }",
        ".card, .card1, .card2, .card3, .card4, .card5 {",
        "  margin: 0; padding: 0; width: auto;",
        "  background: transparent; text-align: left; }",
        "img { max-width: 100%; }",
    }, string.char(10))
end

--- Strip absolute font sizes; `em`/`%` keep inheriting from the chosen base.
--
-- The value is matched whole, not just the number: the old pattern cut
-- `font-size: calc(1em - 2px)` in half, which is a CSS syntax error and makes
-- MuPDF drop every declaration after it.  The declaration is also matched
-- without looking at the previous character, because decks put comments
-- between declarations (`; /* 粉色文字 */\n font-size: ...`), and those were
-- exactly the sheets that kept their pinned sizes.
function Tokens.strip_font_size(css)
    css = tostring(css or "")
    css = css:gsub("font%-size%s*:%s*([^;{}]+)%s*;?", function(value)
        value = value:gsub("%s+$", "")
        if value:find("%d%.?%d*%s*px") or value:find("%d%.?%d*%s*pt") then
            return ""
        end
        return "font-size:" .. value .. ";"
    end)
    return css
end

--- Remove declarations whose value was stripped away.
--
-- Decks ship stylesheets that are already broken (`color: ;` with nothing
-- after the colon is common), and our own stripping can blank a value.  MuPDF
-- stops at the syntax error and drops what follows, so tidy the sheet before
-- handing it over.
function Tokens.tidy_declarations(css)
    css = tostring(css or "")
    local previous
    repeat
        previous = css
        css = css:gsub("([;{]%s*)[%a%-]+%s*:%s*;", "%1")
        css = css:gsub(";%s*;", ";")
        css = css:gsub("{[%s;]*}", "{ }")
        css = css:gsub("%s*;%s*}", " }")
    until css == previous
    return css
end

--- Sanitise a `style="..."` attribute value.
--
-- The template stylesheet is only half the story: notes commonly carry inline
-- `text-align:center` / `margin` / `background` styles that the stylesheet
-- stripper never sees.
function Tokens.sanitize_style_attr(declarations)
    local css = tostring(declarations or "")
    css = Tokens.strip_font_size(css)
    css = Tokens.strip_alignment(css)
    css = Tokens.strip_backgrounds(css)
    return Tokens.tidy_declarations(css)
end

--- Scale a base font size by a percentage, keeping it readable.
-- The card's base size is already clamped for the panel (see `card_font_px`);
-- this only applies the reader's "显示缩放" on top of it.  The floor is the
-- smallest size MuPDF still lays out with sane line spacing on a 300 dpi
-- panel, the ceiling keeps one Chinese glyph inside a third of the width.
function Tokens.scaled_font_px(base, percent)
    base = tonumber(base) or 0
    percent = tonumber(percent) or 100
    if base <= 0 then
        return base
    end
    local px = math.floor(base * percent / 100 + 0.5)
    if px < 12 then
        px = 12
    elseif px > 96 then
        px = 96
    end
    return px
end

--- How wide MuPDF draws one image pixel at the default page scale.
--
-- Measured on the firmware build (KOReader v2026.07.1, 1072 px panel): a 600 px
-- wide PNG occupies 450 px, a 1200 px wide one occupies 900 px.  MuPDF lays
-- HTML out at 72 dpi and treats image pixels as 96 dpi.  CSS `px`, on the other
-- hand, are device pixels: `img { width: 600px }` really is 600 px wide.  So the
-- width we ask for is `natural * 0.75 * zoom`.
local IMAGE_PX_SCALE = 0.75

local function percent_decode(name)
    return (name:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Position of the `>` that closes the tag starting at `start`.
-- Quotes are honoured, so `alt="a > b"` does not end the tag early.
local function tag_end(html, start)
    local quote = nil
    for i = start, #html do
        local c = html:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == ">" then
            return i
        end
    end
    return nil
end

local function src_of(tag)
    return tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]*)"')
        or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']*)'")
        or tag:match("[Ss][Rr][Cc]%s*=%s*([^%s>]+)")
end

--- Rewrite `<img>` tags so the reader's image zoom applies, returning the new
--- HTML and the stylesheet that goes with it.
--
-- MuPDF ignores `img { zoom: ... }`, and a `width="..."` attribute on the tag
-- crashes the renderer outright (reproduced three times on the firmware
-- build), so the only safe route is a class on a wrapper plus a CSS rule:
-- `<div class="ka-zoom-1"><img ...></div>` and `.ka-zoom-1 img { width: Npx }`.
-- Images whose natural size cannot be read (remote URLs, unknown formats) are
-- left exactly as they are.
-- @tparam string html sanitised card body
-- @tparam string resource_dir media directory
-- @tparam number percent 100 leaves the card untouched
-- @treturn string html
-- @treturn string extra stylesheet (empty when nothing was scaled)
function Tokens.scale_images(html, resource_dir, percent)
    html = tostring(html or "")
    percent = tonumber(percent) or 100
    if percent == 100 or type(resource_dir) ~= "string" or resource_dir == "" then
        return html, ""
    end
    local MediaInfo = require("core.media_info")
    local pieces = {}
    local rules = {}
    local index = 0
    local pos = 1
    while true do
        local start = html:find("<img", pos, true) or html:find("<IMG", pos, true)
        if not start then
            pieces[#pieces + 1] = html:sub(pos)
            break
        end
        pieces[#pieces + 1] = html:sub(pos, start - 1)
        local stop = tag_end(html, start)
        if not stop then
            pieces[#pieces + 1] = html:sub(start)
            break
        end
        local tag = html:sub(start, stop)
        local src = src_of(tag)
        local width
        if src and not src:find("^%a+://") and not src:find("^data:") then
            width = MediaInfo.measure(resource_dir .. "/" .. percent_decode(src))
        end
        if width then
            local px = math.floor(width * IMAGE_PX_SCALE * percent / 100 + 0.5)
            if px < 8 then
                px = 8
            elseif px > 4096 then
                px = 4096
            end
            index = index + 1
            local class = "ka-zoom-" .. index
            pieces[#pieces + 1] = string.format('<div class="%s">%s</div>', class, tag)
            rules[#rules + 1] = string.format(".%s img { width: %dpx; }", class, px)
        else
            pieces[#pieces + 1] = tag
        end
        pos = stop + 1
    end
    if #rules == 0 then
        return html, ""
    end
    return table.concat(pieces), table.concat(rules, string.char(10))
end

--- Sanitise every inline style attribute in a card's HTML.
function Tokens.sanitize_html(html)
    html = tostring(html or "")
    html = html:gsub('(style%s*=%s*")([^"]*)(")', function(prefix, value, suffix)
        return prefix .. Tokens.sanitize_style_attr(value) .. suffix
    end)
    html = html:gsub("(style%s*=%s*')([^']*)(')", function(prefix, value, suffix)
        return prefix .. Tokens.sanitize_style_attr(value) .. suffix
    end)
    return html
end

return Tokens
