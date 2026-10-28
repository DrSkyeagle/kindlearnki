--[[--
Anki notetype template evaluation.

This module turns an Anki note type plus a note/card pair into the two HTML
faces the KOReader `HtmlBoxWidget` can display.  It is pure Lua (no KOReader
imports) so `luajit tests/run.lua render` works on a bare Windows box; the UI
layer owns widget construction.

Input shapes are the ones `model.collection` produces:

    notetype = { kind = 0|1, css = "", fields = {{ name = "Front" }, ...},
                 templates = {{ ord = 0, name = "Card 1", qfmt = "...", afmt = "..." }} }
    note     = { fields = { "value of ord 0", ... }, tags = "tag1 tag2" }
    card     = { ord = 0 }
    context  = { deck_name = "Japanese::N5", card_name = "Card 1" }

`card_faces` returns

    { question_html = "...", answer_html = "...",
      media = { ["cat.png"] = true }, css = "...",
      errors = { ... }, ok = true|false }

Field values are HTML and are emitted verbatim: the note type owns its markup,
and re-escaping it would show `<b>` to the user as literal text.

Two things are still removed from the finished faces:
  * `<style>` blocks — per the render contract the note type CSS travels in
    `css` (the widget's `css` parameter), never inline in the face; and
  * `[sound:...]` markers — KOReader has no audio playback here, so they become
    a Chinese placeholder rather than a dead file reference.

Cloze semantics follow Anki rather than a literal reading of "bold the active
cloze": the *question* side hides the active cloze (`[...]`) or the answer
would be visible before the user answers; the *answer* side bolds it and puts
the hint in a `title` attribute.  The question side shows a hint in parentheses
because it is the only face where the hint is useful.

Deliberate degradations (documented rather than silently wrong):
  * `{{type:Field}}` becomes the plain field plus a note saying typing cards are
    self-graded here;
  * `{{hint:Field}}` becomes `（提示：字段名）` instead of a hint button;
  * filters we do not implement (`tts`, `furigana`, `kanji`, ...) are dropped and
    the field name after the last colon is rendered as a plain field, matching
    the contract's "unknown filter must not raise";
  * template/CSS sanitising is *not* done here: `render/sanitize.lua` is a
    separate step so that `card_faces` stays predictable in tests.
]]

local M = {}

local TYPE_FALLBACK_HTML = "<div>（输入型卡片已降级为自评）</div>"
local SOUND_PLACEHOLDER = "（音频）"

-- Elements whose content must never reach a card as visible text.  The `text`
-- filter is the only place this matters: a field can contain a stray
-- <script>, and showing its source as prose is worse than dropping it.
local TEXT_DROP_ELEMENTS = { "script", "style", "iframe", "object", "embed", "svg", "math" }

--==========================================================================
-- Small string helpers
--==========================================================================

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function to_text(value)
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    return tostring(value)
end

--- Escape a value that goes inside a double-quoted attribute.  `&` is left
--- alone on purpose: source values are already HTML and re-escaping `&amp;`
--- would corrupt URLs.
local function escape_attr(value)
    return (to_text(value)
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

--- Find the `>` that closes the tag starting at `from`, skipping `>` inside
--- quoted attribute values.  Returns nil when the input has no closing `>`.
local function find_tag_end(text, from)
    local index = from
    local length = #text
    local quote = nil
    while index <= length do
        local char = text:sub(index, index)
        if quote then
            if char == quote then
                quote = nil
            end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char == ">" then
            return index
        end
        index = index + 1
    end
    return nil
end

--- Minimal attribute parser.  Unquoted, single-quoted and double-quoted values
--- all occur in hand-written Anki templates, so a regex-only approach would
--- miss real input.  Returns an ordered list of { name = ..., value = ... }.
local function parse_attributes(text)
    local attributes = {}
    local length = #text
    local index = 1
    while index <= length do
        local name_start = text:find("[%w_:%-]", index)
        if not name_start then
            break
        end
        local name_end = text:find("[^%w_:%-]", name_start) or (length + 1)
        local name = text:sub(name_start, name_end - 1):lower()
        index = name_end

        local value = ""
        local equals_at = text:find("%S", index)
        if equals_at and text:sub(equals_at, equals_at) == "=" then
            local value_start = text:find("%S", equals_at + 1)
            if value_start then
                local quote = text:sub(value_start, value_start)
                if quote == '"' or quote == "'" then
                    local close = text:find(quote, value_start + 1, true)
                    if close then
                        value = text:sub(value_start + 1, close - 1)
                        index = close + 1
                    else
                        value = text:sub(value_start + 1)
                        index = length + 1
                    end
                else
                    local value_end = text:find("%s", value_start) or (length + 1)
                    value = text:sub(value_start, value_end - 1)
                    index = value_end
                end
            else
                index = length + 1
            end
        else
            -- Boolean attribute (`<img alt>`); keep it with an empty value so
            -- the sanitizer's whitelist decides what to do with it.
            index = equals_at or (length + 1)
        end
        attributes[#attributes + 1] = { name = name, value = value }
    end
    return attributes
end

--==========================================================================
-- Face post-processing
--==========================================================================

--- Remove `<style>...</style>` blocks, case-insensitively and lazily.
--- The contract puts note type CSS in `css`, so style blocks in a face are
--- either legacy template cruft or something that must not be inlined.
local function strip_style_blocks(html)
    local lower = html:lower()
    local out = {}
    local position = 1
    local length = #html
    while position <= length do
        local start_pos = lower:find("<style", position, true)
        if not start_pos then
            out[#out + 1] = html:sub(position)
            break
        end
        out[#out + 1] = html:sub(position, start_pos - 1)
        local close_start = lower:find("</style", start_pos + 6, true)
        if not close_start then
            -- Unterminated style block: drop the rest, there is no safe way to
            -- tell CSS from card content.
            break
        end
        local close_end = lower:find(">", close_start + 7, true)
        if not close_end then
            break
        end
        position = close_end + 1
    end
    return table.concat(out)
end

local function replace_sound_markers(html)
    return (html:gsub("%[sound:[^%]]*%]", SOUND_PLACEHOLDER))
end

--- Remove one element together with its content (used by the `text` filter).
local function drop_element(text, name)
    local lower = text:lower()
    local open_tag = "<" .. name
    local close_tag = "</" .. name
    local out = {}
    local position = 1
    local length = #text
    while position <= length do
        local start_pos = lower:find(open_tag, position, true)
        if not start_pos then
            out[#out + 1] = text:sub(position)
            break
        end
        local boundary = lower:sub(start_pos + #open_tag, start_pos + #open_tag)
        if boundary ~= "" and boundary:match("[%w%-_]") then
            -- `<scriptx` is not `<script`.
            out[#out + 1] = text:sub(position, start_pos + #open_tag - 1)
            position = start_pos + #open_tag
        else
            out[#out + 1] = text:sub(position, start_pos - 1)
            local close_start = lower:find(close_tag, start_pos + #open_tag, true)
            if not close_start then
                position = length + 1
            else
                local close_end = text:find(">", close_start + #close_tag, true)
                position = close_end and (close_end + 1) or (length + 1)
            end
        end
    end
    return table.concat(out)
end

--- `{{text:Field}}`: strip markup, keep the words.  `<br>` becomes a space so
--- words on separate lines do not run together.
local function strip_html_tags(text)
    local stripped = text
    for index = 1, #TEXT_DROP_ELEMENTS do
        stripped = drop_element(stripped, TEXT_DROP_ELEMENTS[index])
    end
    stripped = stripped:gsub("<!%-%-.-%-%->", "")
    stripped = stripped:gsub("<br%s*/?>", " ")
    return (stripped:gsub("<%/?[%a][^>]*>", ""))
end

--- Media files referenced by the finished faces.  Only local, relative
--- references are useful: `http:`/`data:` images are not on the device and
--- cannot be fetched by the study screen.
local function local_media_name(source)
    local name = trim(source)
    name = name:gsub("^%./", "")
    if name == "" then
        return nil
    end
    local scheme = name:lower():match("^([%a][%w%+%-%.]*):")
    if scheme then
        return nil
    end
    return name
end

local function collect_media(html, media)
    local lower = html:lower()
    local position = 1
    local length = #html
    while position <= length do
        local start_pos = lower:find("<img", position, true)
        if not start_pos then
            break
        end
        local boundary = lower:sub(start_pos + 4, start_pos + 4)
        if boundary ~= "" and boundary:match("[%w%-_]") then
            position = start_pos + 4
        else
            local tag_end = find_tag_end(html, start_pos + 4)
            if not tag_end then
                break
            end
            local tag_text = html:sub(start_pos, tag_end)
            local attributes_text = tag_text:match("^<%a+[%w_:%-]*(.*)>$") or ""
            attributes_text = attributes_text:gsub("/%s*$", "")
            local attributes = parse_attributes(attributes_text)
            for attribute_index = 1, #attributes do
                if attributes[attribute_index].name == "src" then
                    local name = local_media_name(attributes[attribute_index].value)
                    if name then
                        media[name] = true
                    end
                    break
                end
            end
            position = tag_end + 1
        end
    end
end

local function finalize_html(html)
    return replace_sound_markers(strip_style_blocks(html))
end

--==========================================================================
-- Expression / template parsing
--==========================================================================

--- Split `filter1:filter2:Field` into filters and the trailing field name.
--- Anki names cannot contain `:`, so the last colon is always the separator;
--- this is also what makes unknown filters (`tts ja:Field`) degrade to `Field`.
local function split_expression(expression)
    local segments = {}
    local start = 1
    while true do
        local colon = expression:find(":", start, true)
        if not colon then
            segments[#segments + 1] = expression:sub(start)
            break
        end
        segments[#segments + 1] = expression:sub(start, colon - 1)
        start = colon + 1
    end
    local filters = {}
    for index = 1, #segments - 1 do
        local filter = trim(segments[index])
        if filter ~= "" then
            filters[#filters + 1] = filter
        end
    end
    return filters, trim(segments[#segments])
end

local function append_text(parent, text)
    if text == "" then
        return
    end
    local last = parent.children[#parent.children]
    if last and last.kind == "text" then
        last.text = last.text .. text
    else
        parent.children[#parent.children + 1] = { kind = "text", text = text }
    end
end

--- Parse a template into a node tree.
--
-- A section that is opened and never closed makes the whole template
-- unparseable.  `card_faces` then renders the template text verbatim and
-- records an error, which is the contract's "报错并降级为原文": showing the
-- user their own template is recoverable, showing half-rendered markup is not.
local function parse_template(text)
    local root = { kind = "root", children = {} }
    local stack = { root }
    local position = 1
    local length = #text
    while position <= length do
        local open_start, open_end = text:find("{{", position, true)
        if not open_start then
            append_text(stack[#stack], text:sub(position))
            break
        end
        if open_start > position then
            append_text(stack[#stack], text:sub(position, open_start - 1))
        end

        local close_start, close_end = text:find("}}", open_end + 1, true)
        if not close_start then
            -- No closing braces anywhere: keep the rest literal.  This is a
            -- truncated template, not an unbalanced section.
            append_text(stack[#stack], text:sub(open_start))
            break
        end

        local inner = trim(text:sub(open_end + 1, close_start - 1))
        position = close_end + 1

        local marker = inner:sub(1, 1)
        if marker == "#" or marker == "^" then
            local filters, name = split_expression(trim(inner:sub(2)))
            local section = {
                kind = "section",
                open = marker,
                name = name,
                raw_name = trim(inner:sub(2)),
                filters = filters,
                children = {},
            }
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = section
            stack[#stack + 1] = section
        elseif marker == "/" then
            local name = trim(inner:sub(2))
            local opened = stack[#stack]
            if #stack == 1 or opened.raw_name ~= name then
                return nil, string.format("unmatched closing tag {{/%s}}", name)
            end
            stack[#stack] = nil
        elseif marker == "!" then
            -- Anki comment ({{! ... }}); not rendered.
        elseif inner == "" then
            append_text(stack[#stack], "{{}}")
        else
            local filters, name = split_expression(inner)
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = {
                kind = "field",
                name = name,
                filters = filters,
            }
        end
    end

    if #stack > 1 then
        local opened = stack[#stack]
        return nil, string.format("unclosed section {{%s%s}}", opened.open, opened.raw_name)
    end
    return root
end

--==========================================================================
-- Value resolution
--==========================================================================

-- Special field names are matched case-insensitively: Anki treats them as
-- built-ins, so a note that happens to have a field called "type" cannot
-- shadow the special either.
local SPECIAL_FIELDS = {
    frontside = true,
    tags = true,
    deck = true,
    subdeck = true,
    card = true,
    type = true,
}

local function special_name(name)
    if type(name) ~= "string" then
        return nil
    end
    local lowered = name:lower()
    if SPECIAL_FIELDS[lowered] then
        return lowered
    end
    return nil
end

local function tags_value(note)
    local tags = note.tags
    if tags == nil then
        return ""
    end
    if type(tags) == "table" then
        local parts = {}
        for index = 1, #tags do
            parts[index] = to_text(tags[index])
        end
        return table.concat(parts, " ")
    end
    return to_text(tags)
end

local function deck_name(context)
    local name = context.deck_name
    return name and to_text(name) or ""
end

local function card_type(ctx)
    if tonumber(ctx.notetype.kind) == 1 then
        return "Cloze"
    end
    if ctx.card_ord == 0 then
        return "Forward"
    end
    return "Reverse"
end

local function special_value(special, ctx)
    if special == "frontside" then
        -- FrontSide only exists on the answer face; on the question face Anki
        -- renders it as nothing.
        if ctx.face == "answer" then
            return ctx.front_side
        end
        return ""
    elseif special == "tags" then
        return tags_value(ctx.note)
    elseif special == "deck" then
        return deck_name(ctx.context)
    elseif special == "subdeck" then
        -- Anki's Subdeck is the leaf name: "Japanese::N5" -> "N5".
        return (deck_name(ctx.context):match("[^:]+$")) or deck_name(ctx.context)
    elseif special == "card" then
        local card_name = ctx.context.card_name
        if card_name ~= nil and card_name ~= "" then
            return to_text(card_name)
        end
        return ctx.template and to_text(ctx.template.name) or ""
    elseif special == "type" then
        return card_type(ctx)
    end
    return ""
end

local function field_value(ctx, name)
    local index = ctx.field_index[name]
    if not index then
        return ""
    end
    return to_text(ctx.note.fields and ctx.note.fields[index] or nil)
end

local function resolve_value(name, ctx)
    local special = special_name(name)
    if special then
        return special_value(special, ctx)
    end
    return field_value(ctx, name)
end

--- Anki shows a `{{#Field}}` section when the field is not empty.  Sound
--- markers and NBSP count as blank because they render as nothing visible;
--- images and other markup do not, so `<img>`-only fields still show.
local function is_blank(value)
    if value == nil then
        return true
    end
    local text = to_text(value)
    if text == "" then
        return true
    end
    text = text:gsub("%[sound:[^%]]*%]", "")
    text = text:gsub("&nbsp;", ""):gsub("&#160;", "")
    return text:find("%S") == nil
end

--==========================================================================
-- Cloze
--==========================================================================

local CLOZE_PATTERN = "{{c(%d+)::(.-)}}"

local function render_cloze(text, ctx)
    local reveal = ctx.face == "answer"
    local active = ctx.cloze_ord
    local out = {}
    local position = 1
    while true do
        local start_pos, end_pos, number, body = text:find(CLOZE_PATTERN, position)
        if not start_pos then
            out[#out + 1] = text:sub(position)
            break
        end
        out[#out + 1] = text:sub(position, start_pos - 1)

        -- `{{c1::answer::hint}}`: hint may itself contain colons.
        local answer, hint = body:match("^(.-)::(.*)$")
        if answer == nil then
            answer, hint = body, nil
        end

        if tonumber(number) == active then
            if reveal then
                if hint and hint ~= "" then
                    out[#out + 1] = '<b><span title="' .. escape_attr(hint) .. '">'
                        .. answer .. "</span></b>"
                else
                    out[#out + 1] = "<b>" .. answer .. "</b>"
                end
            elseif hint and hint ~= "" then
                -- The hint only helps on the question face; keep it visible
                -- (in parentheses) exactly where it is needed.
                out[#out + 1] = "[...]（" .. hint .. "）"
            else
                out[#out + 1] = "[...]"
            end
        else
            out[#out + 1] = "[...]"
        end

        position = end_pos + 1
    end
    return table.concat(out)
end

--==========================================================================
-- Filters
--==========================================================================

local function apply_filter(filter, value, field_name, ctx)
    local lowered = filter:lower()
    if lowered == "text" then
        return strip_html_tags(value)
    elseif lowered == "cloze" then
        return render_cloze(value, ctx)
    elseif lowered == "type" then
        return value .. TYPE_FALLBACK_HTML
    elseif lowered == "hint" then
        return "（提示：" .. field_name .. "）"
    end
    -- Unknown filter: render the field unchanged.  Anki's tts/furigana/kanji
    -- filters cannot be honoured on the device, and raising here would make an
    -- otherwise readable card unopenable.
    return value
end

--==========================================================================
-- Rendering
--==========================================================================

local function render_nodes(nodes, ctx, out)
    for index = 1, #nodes do
        local node = nodes[index]
        if node.kind == "text" then
            out[#out + 1] = node.text
        elseif node.kind == "section" then
            local present = not is_blank(resolve_value(node.name, ctx))
            if present == (node.open == "#") then
                render_nodes(node.children, ctx, out)
            end
        else
            local value = resolve_value(node.name, ctx)
            for filter_index = #node.filters, 1, -1 do
                value = apply_filter(node.filters[filter_index], value, node.name, ctx)
            end
            out[#out + 1] = value
        end
    end
end

local function render_face(nodes, ctx)
    local out = {}
    render_nodes(nodes, ctx, out)
    return table.concat(out)
end

--==========================================================================
-- Public API
--==========================================================================

local function card_faces_impl(notetype, note, card, context)
    local errors = {}

    local field_index = {}
    local fields = notetype.fields or {}
    for index = 1, #fields do
        local definition = fields[index]
        local name
        if type(definition) == "table" then
            name = definition.name
        elseif type(definition) == "string" then
            name = definition
        end
        -- The first definition wins: a collection with duplicate field names
        -- is broken, but the renderer must still pick a deterministic slot.
        if name ~= nil and field_index[name] == nil then
            field_index[name] = index
        end
    end

    local templates = notetype.templates or {}
    local template_by_ord = {}
    for index = 1, #templates do
        local template = templates[index]
        if type(template) == "table" then
            local template_ord = tonumber(template.ord)
            if template_ord ~= nil and template_by_ord[template_ord] == nil then
                template_by_ord[template_ord] = template
            end
        end
    end

    local card_ord = tonumber(card.ord) or 0
    local template = template_by_ord[card_ord]
    if not template then
        -- The card's template may have been deleted while its cards were not;
        -- falling back keeps the card reviewable instead of blank.
        template = templates[card_ord + 1] or templates[1] or {}
    end
    if type(template) ~= "table" then
        template = {}
    end

    local ctx = {
        notetype = notetype,
        note = note,
        context = context,
        template = template,
        field_index = field_index,
        card_ord = card_ord,
        -- A cloze card's ord is the 0-based cloze index.
        cloze_ord = card_ord + 1,
        face = "question",
        front_side = "",
    }

    local question_template = to_text(template.qfmt)
    local question_html
    local question_nodes, question_error = parse_template(question_template)
    if question_nodes then
        question_html = render_face(question_nodes, ctx)
    else
        errors[#errors + 1] = "question template: " .. tostring(question_error)
        question_html = question_template
    end
    question_html = finalize_html(question_html)

    ctx.face = "answer"
    ctx.front_side = question_html

    local answer_template = to_text(template.afmt)
    local answer_html
    local answer_nodes, answer_error = parse_template(answer_template)
    if answer_nodes then
        answer_html = render_face(answer_nodes, ctx)
    else
        errors[#errors + 1] = "answer template: " .. tostring(answer_error)
        answer_html = answer_template
    end
    answer_html = finalize_html(answer_html)

    local media = {}
    collect_media(question_html, media)
    collect_media(answer_html, media)

    return {
        question_html = question_html,
        answer_html = answer_html,
        media = media,
        -- The CSS is handed through untouched: the widget (or the screen
        -- owning it) decides whether to pass it through render/sanitize.lua.
        css = to_text(notetype.css),
        errors = errors,
        ok = #errors == 0,
    }
end

--- Render both faces of a card.
-- @tparam table notetype decoded note type (see module header)
-- @tparam table note     decoded note
-- @tparam table card     at least { ord = <number> }
-- @tparam table context  { deck_name = ..., card_name = ... }
-- @treturn table { question_html, answer_html, media, css, errors, ok }
function M.card_faces(notetype, note, card, context)
    notetype = type(notetype) == "table" and notetype or {}
    note = type(note) == "table" and note or {}
    card = type(card) == "table" and card or {}
    context = type(context) == "table" and context or {}

    -- A template syntax error is handled above; this pcall only covers a bug
    -- in this module.  A study screen that dies while rendering one card is a
    -- much worse failure mode than a card that shows its template text.
    local ok, result = pcall(card_faces_impl, notetype, note, card, context)
    if ok then
        return result
    end

    local fallback_question = ""
    local fallback_answer = ""
    local first_template = (notetype.templates or {})[1]
    if type(first_template) == "table" then
        fallback_question = to_text(first_template.qfmt)
        fallback_answer = to_text(first_template.afmt)
    end
    return {
        question_html = fallback_question,
        answer_html = fallback_answer,
        media = {},
        css = to_text(notetype.css),
        errors = { "render failed: " .. tostring(result) },
        ok = false,
    }
end

return M
