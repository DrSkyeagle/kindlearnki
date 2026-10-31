--[[--
Drawing primitives shared by the deck screen and the study screen.

Why this file exists instead of KOReader's TextWidget / TextBoxWidget stack:

  * The two screens repaint whenever a card changes face or the answer bar
    appears.  Each repaint must not allocate BlitBuffers: a TextBoxWidget builds
    a fresh buffer on every `init()` and a leaked one is a real leak on a 512 MB
    Voyage (the renderer runs for hours).  Drawing straight into the screen
    buffer keeps the repaint allocation-free -- text is measured and wrapped
    once per card, then blitted.
  * KOReader's layout widgets are built from nested containers with automatic
    sizing; the design here is a fixed grid (margins, rules, equal rating
    columns) so the arithmetic is simpler and easier to keep pixel-true.

Everything is defensive: a missing face or a failed render degrades to "no
pixels" rather than an error inside `paintTo`, which KOReader would only log as
one line in crash.log.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local util = require("util")

local Tokens = require("ui.tokens")

local Widgets = {}

--==========================================================================
-- Colour
--==========================================================================

-- The design fixes two inks; a greyscale panel (and KOReader's device dependent
-- colour objects: plain numbers on BB8, ColorRGB32 on colour hosts) cannot take
-- a raw "#111111".  The tokens therefore map onto KOReader's own black/white
-- constants, which are correct on every buffered screen type.
local HEX_KIND = {
    ["#FFFFFF"] = "paper",
    ["#111111"] = "ink",
}

--- Translate a design colour token into a BlitBuffer colour.
-- Unknown tokens fall back on luminance, so adding a token cannot crash a paint.
-- @string hex `#RRGGBB`
-- @treturn int|table BlitBuffer colour
function Widgets.color(hex)
    local kind = HEX_KIND[hex]
    if not kind then
        local r, g, b = Tokens.hex_to_rgb(hex)
        kind = (0.299 * r + 0.587 * g + 0.114 * b) < 128 and "ink" or "paper"
    end
    if kind == "paper" then
        return Blitbuffer.COLOR_WHITE
    end
    return Blitbuffer.COLOR_BLACK
end

--- The only two colours a screen needs, resolved once per paint.
-- @treturn table { ink = <color>, paper = <color> }
function Widgets.colors()
    return {
        ink = Widgets.color(Tokens.color.ink),
        paper = Widgets.color(Tokens.color.paper),
    }
end

--==========================================================================
-- Metrics
--==========================================================================

-- Keyed by face table (KOReader caches faces, so these keys are stable) and then
-- by the extra line height.  Avoids calling into FreeType on every repaint.
local metrics_cache = {}
local width_cache = {}

--- Line box for `face` with `extra` additional line height (0.65 = design 1.65).
--
-- Mirrors TextBoxWidget's maths (`line_height_px = round((1 + line_height) *
-- face.size)`, baseline centred in the leftover space) so our own drawing has
-- exactly the rhythm the design was verified with.
--
-- @tparam table face
-- @number[opt] extra
-- @treturn table { h, baseline, ascent, face_height }
function Widgets.metrics(face, extra)
    if not face then
        return { h = 0, baseline = 0, ascent = 0, face_height = 0 }
    end
    extra = extra or 0
    local by_extra = metrics_cache[face]
    if not by_extra then
        by_extra = {}
        metrics_cache[face] = by_extra
    end
    local cached = by_extra[extra]
    if cached then
        return cached
    end

    local face_height = face.size or 0
    local face_ascender = (face.size or 0) * 0.75
    if face.ftsize then
        local ok, height, ascender = pcall(face.ftsize.getHeightAndAscender, face.ftsize)
        if ok and height then
            face_height = height
            face_ascender = ascender or face_ascender
        end
    end
    local line_height = math.floor((1 + extra) * (face.size or 0) + 0.5)
    if line_height < math.ceil(face_height) then
        -- With no extra line height the glyph box *is* the line box; a line
        -- shorter than the glyphs would clip ascenders/descenders.
        line_height = math.ceil(face_height)
    end
    local diff = math.floor(line_height - face_height)
    local baseline
    if diff >= 0 then
        baseline = math.floor(face_ascender + diff / 2)
    else
        baseline = math.floor(face_ascender)
    end
    local result = {
        h = line_height,
        baseline = baseline,
        ascent = math.ceil(face_ascender),
        face_height = math.ceil(face_height),
    }
    by_extra[extra] = result
    return result
end

--- Advance width of one UTF-8 character, cached per face.
-- @tparam table face
-- @string char
-- @treturn number
function Widgets.char_width(face, char)
    local by_char = width_cache[face]
    if not by_char then
        by_char = {}
        width_cache[face] = by_char
    end
    local width = by_char[char]
    if width == nil then
        local size
        local ok = pcall(function()
            size = RenderText:sizeUtf8Text(0, false, face, char, false, false)
        end)
        width = (ok and size and size.x) or 0
        by_char[char] = width
    end
    return width
end

--- Width of a whole string, measured the same way the wrapper measures.
-- @tparam table face
-- @string text
-- @treturn number
function Widgets.text_width(face, text)
    if not face or type(text) ~= "string" or text == "" then
        return 0
    end
    local size
    local ok = pcall(function()
        size = RenderText:sizeUtf8Text(0, false, face, text, false, false)
    end)
    return (ok and size and size.x) or 0
end

--==========================================================================
-- Text layout
--==========================================================================

--- Truncate `text` to `max_width` with a trailing ellipsis (`…`).
-- @tparam table face
-- @string text
-- @number max_width
-- @treturn string
function Widgets.truncate(face, text, max_width)
    if not face or type(text) ~= "string" or text == "" then
        return ""
    end
    if max_width <= 0 then
        return ""
    end
    if Widgets.text_width(face, text) <= max_width then
        return text
    end
    local ok, truncated = pcall(RenderText.truncateTextByWidth, RenderText,
        text, face, max_width, false, false)
    if ok and type(truncated) == "string" and truncated ~= "" then
        return truncated
    end
    return ""
end

--- Greedy line breaking, CJK-aware (through `util.isSplittable`).
--
-- Wrapping happens once per card text, never per repaint: the result is cached
-- by the caller.  Returns an array of strings, no trailing spaces.
--
-- @tparam table face
-- @string text
-- @number width available width in pixels
-- @treturn table lines
function Widgets.wrap(face, text, width)
    local lines = {}
    if not face or type(text) ~= "string" or text == "" or width <= 0 then
        return lines
    end
    local chars = util.splitToChars(text)
    local count = #chars
    local line_start = 1
    local line_width = 0
    local break_at -- index of the first char of the next line, when breaking here is legal
    local index = 1

    local function push_line(first, last)
        local line = table.concat(chars, "", first, last)
        line = line:gsub(" +$", "") -- a trailing space is invisible but wastes width
        lines[#lines + 1] = line
    end

    while index <= count do
        local char = chars[index]
        if char == "\n" then
            push_line(line_start, index - 1)
            index = index + 1
            line_start = index
            line_width = 0
            break_at = nil
        else
            local char_width = Widgets.char_width(face, char)
            if line_width + char_width > width and index > line_start then
                local cut = break_at or index
                if cut <= line_start then
                    -- Defensive: never emit an "empty" line (table.concat would
                    -- reject it) even if a future break rule returns nonsense.
                    cut = index
                end
                push_line(line_start, cut - 1)
                line_start = cut
                -- Re-measure the part that carries over, then look at this char
                -- again against the shorter line.
                line_width = 0
                for carried = line_start, index - 1 do
                    line_width = line_width + Widgets.char_width(face, chars[carried])
                end
                break_at = nil
            else
                line_width = line_width + char_width
                local next_char = chars[index + 1]
                if next_char and next_char ~= "\n"
                    and util.isSplittable(char, next_char, chars[index - 1]) then
                    break_at = index + 1
                end
                index = index + 1
            end
        end
    end
    if line_start <= count then
        push_line(line_start, count)
    end
    return lines
end

--- Height of a wrapped block plus its baselines, ready for `Widgets.draw`.
-- @tparam table face
-- @tparam table lines
-- @number[opt] extra
-- @treturn table { height = px, baselines = { px, ... } }
function Widgets.block_metrics(face, lines, extra)
    local metrics = Widgets.metrics(face, extra)
    local baselines = {}
    local count = lines and #lines or 0
    for index = 1, count do
        baselines[index] = (index - 1) * metrics.h + metrics.baseline
    end
    return { height = count * metrics.h, baselines = baselines, line_height = metrics.h }
end

--==========================================================================
-- Painting
--==========================================================================

--- Fill a rectangle.  Used for the page background and the answer bar.
-- @tparam BlitBuffer bb
-- @int x
-- @int y
-- @int w
-- @int h
-- @tparam int|table color
function Widgets.rect(bb, x, y, w, h, color)
    if not bb or w <= 0 or h <= 0 then
        return
    end
    bb:paintRect(x, y, w, h, color)
end

--- Draw one run of text at `baseline`.
-- @tparam BlitBuffer bb
-- @int x
-- @number baseline
-- @tparam table face
-- @string text
-- @tparam int|table color
-- @number[opt] max_width
-- @bool[opt] bold
-- @treturn number pen position after the last glyph
function Widgets.draw(bb, x, baseline, face, text, color, max_width, bold)
    if not bb or not face or type(text) ~= "string" or text == "" then
        return 0
    end
    local pen = 0
    pcall(function()
        pen = RenderText:renderUtf8Text(bb, x, baseline, face, text,
            false, bold or false, color, max_width)
    end)
    return pen or 0
end

--- Draw text so that it ends at `x_right` (right aligned).
-- @treturn number the x it started at
function Widgets.draw_right(bb, x_right, baseline, face, text, color, max_width, bold)
    local width = Widgets.text_width(face, text)
    if max_width and width > max_width then
        text = Widgets.truncate(face, text, max_width)
        width = Widgets.text_width(face, text)
    end
    local x = x_right - width
    Widgets.draw(bb, x, baseline, face, text, color, max_width, bold)
    return x
end

--- Draw text centred inside `[x, x + width]`.
function Widgets.draw_centered(bb, x, width, baseline, face, text, color, bold)
    local text_width = Widgets.text_width(face, text)
    local text_x = x + math.floor((width - text_width) / 2)
    if text_x < x then
        text_x = x
    end
    Widgets.draw(bb, text_x, baseline, face, text, color, width, bold)
end

--- Solid rule (1px 墨线 / 2px 进度线).
function Widgets.rule(bb, x, y, width, thickness, color)
    Widgets.rect(bb, x, y, width, thickness or Tokens.size.hairline, color)
end

--- Dotted leader, as used between a deck name and its count.
-- @int dot diameter
-- @int gap space between dots
function Widgets.dotted_rule(bb, x, y, width, color, dot, gap, thickness)
    dot = dot or Tokens.size.dot
    gap = gap or Tokens.size.dot_gap
    thickness = thickness or dot
    if not bb or width <= 0 then
        return
    end
    local step = dot + gap
    local cursor = x
    while cursor + dot <= x + width do
        bb:paintRect(cursor, y, dot, thickness, color)
        cursor = cursor + step
    end
end

--- Rectangle within the screen buffer, for hit zones that must be testable.
-- @int x
-- @int y
-- @int w
-- @int h
-- @treturn table Geom
function Widgets.box(x, y, w, h)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

--- Strip markup so a card can still be shown when the HTML renderer is missing.
-- @string html
-- @treturn string
function Widgets.to_plain_text(html)
    if type(html) ~= "string" then
        return ""
    end
    local ok_util, plain = pcall(function()
        return util.htmlToPlainText(html)
    end)
    if ok_util and type(plain) == "string" then
        return plain
    end
    -- Last resort: a crude tag strip beats a blank page or an error in paintTo.
    local stripped = html:gsub("<[^>]*>", " ")
    stripped = stripped:gsub("&nbsp;", " ")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&amp;", "&")
    return stripped
end

return Widgets
