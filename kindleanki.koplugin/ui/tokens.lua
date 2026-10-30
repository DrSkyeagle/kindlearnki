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
    local by_width = math.floor(width / 26)
    local by_height = math.floor(height / 34)
    local px = math.min(by_width, by_height)
    if px < 24 then
        px = 24
    elseif px > 64 then
        px = 64
    end
    return px
end

--- Remove pinned `font-size` declarations so the adaptive size wins.
--
-- The cascade would otherwise let the template's px value override the base
-- font passed to the HTML box.  `em`/`%` sizes that remain inherit from the new
-- base, which keeps relative emphasis intact.
function Tokens.strip_font_size(css)
    css = tostring(css or "")
    -- Only absolute units: `em`/`%` should keep inheriting from the new base.
    css = css:gsub("font%-size%s*:%s*[%d%.]+%s*px%s*;?", "")
    css = css:gsub("font%-size%s*:%s*[%d%.]+%s*pt%s*;?", "")
    return css
end

return Tokens

