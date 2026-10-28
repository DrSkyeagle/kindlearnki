--[[--
HTML / CSS sanitising for card content.

Card content comes from a synced collection, so it is data, not code: a template
or a field could contain a `<script>`, an `onclick=` handler or a `javascript:`
URL.  The study screen hands the result to KOReader's `HtmlBoxWidget`, which
does not run scripts, but sanitising here means a future HTML surface (or an
exported file) cannot become a hole, and it keeps malformed markup from
confusing the (very simple) ebook renderer.

Two entry points only, both total functions: any input type yields a string and
nothing raises.

    Sanitize.html(raw) -> string
    Sanitize.css(raw)  -> string

The whitelist is intentionally narrow; anything not listed is dropped.  That is
the opposite of a blacklist, which is why each rule below is short and auditable.

Note on Lua patterns: there is no `|` alternation, so element lists are handled
by iterating a table (or by explicit `find` loops) rather than by one clever
pattern.  Container elements are removed with a find-the-closing-tag loop, not
with `<script>.-</script>`-style patterns, so attributes and uppercase tags are
handled and the removal is guaranteed to terminate.
]]

local M = {}

--==========================================================================
-- Whitelists
--==========================================================================

local ALLOWED_TAGS = {
    b = true, i = true, u = true, s = true, em = true, strong = true,
    div = true, p = true, span = true, br = true, hr = true,
    table = true, thead = true, tbody = true, tr = true, td = true, th = true,
    ul = true, ol = true, li = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    blockquote = true, pre = true, code = true,
    font = true, img = true, a = true, sub = true, sup = true, center = true,
}

-- Never printed without a matching closing tag.
local VOID_TAGS = { br = true, hr = true, img = true }

-- Removed together with their content.
local DROP_WITH_CONTENT = {
    script = true, style = true, iframe = true, object = true, form = true,
    audio = true, video = true, svg = true, math = true,
}

-- Void elements that only need their own tag removed (no content exists).
local DROP_TAG_ONLY = { input = true, link = true, meta = true, embed = true }

-- Attribute whitelist per element.  Everything else, in particular every
-- `on*` handler, is dropped simply by not being listed.
local ALLOWED_ATTRIBUTES = {
    img = { src = true, alt = true, width = true, height = true },
    font = { color = true, face = true, size = true },
    td = { colspan = true, rowspan = true },
    th = { colspan = true, rowspan = true },
    a = { href = true },
    div = { style = true },
    p = { style = true },
    span = { style = true },
}

--==========================================================================
-- Scanners shared by tags, attributes and CSS
--==========================================================================

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Find the `>` closing a tag, skipping `>` inside quoted attribute values.
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

--- Split a tag into name / closing / self-closing / raw attribute text.
local function parse_tag(raw, lt, gt)
    local index = lt + 1
    local closing = false
    if raw:sub(index, index) == "/" then
        closing = true
        index = index + 1
    end
    local name_start = index
    while index <= gt do
        if not raw:find("^[%w_:%-]", index) then
            break
        end
        index = index + 1
    end
    local name = raw:sub(name_start, index - 1):lower()
    if name == "" then
        return nil
    end

    local attributes_text = raw:sub(index, gt - 1)
    local self_closing = false
    local trimmed = attributes_text:gsub("%s+$", "")
    if trimmed:sub(-1) == "/" then
        self_closing = true
        attributes_text = trimmed:sub(1, -2)
    end
    return name, closing, self_closing, attributes_text
end

--- Parse attribute text into an ordered list of { name = ..., value = ... }.
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
            index = equals_at or (length + 1)
        end
        attributes[#attributes + 1] = { name = name, value = value }
    end
    return attributes
end

local function escape_attribute(value)
    -- `&` is preserved: values are HTML already, and re-escaping it would
    -- break query strings and entities that reached us correctly.
    return (value
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

--==========================================================================
-- URLs
--==========================================================================

--- Decode the numeric character references that are commonly used to hide a
--- scheme (`jav&#x61;script:`).  Only ASCII range matters for URL schemes.
local function decode_numeric_entities(value)
    local decoded = value:gsub("&#[xX](%x+);", function(hex)
        local code = tonumber(hex, 16)
        if code and code > 0 and code < 128 then
            return string.char(code)
        end
        return ""
    end)
    decoded = decoded:gsub("&#(%d+);", function(decimal)
        local code = tonumber(decimal)
        if code and code > 0 and code < 128 then
            return string.char(code)
        end
        return ""
    end)
    return decoded
end

--- Normalise a URL enough to judge its scheme: lowercase, decode numeric
--- entities, strip whitespace/control characters and backslashes, all of which
--- browsers ignore or decode inside a URL.
local function url_scheme(value)
    local probe = decode_numeric_entities(value:lower())
    probe = probe:gsub("&colon;", ":")
    probe = probe:gsub("[%z\1-\32]", "")
    probe = probe:gsub("\\", "")
    return probe:match("^([%a][%w%+%-%.]*):")
end

local DANGEROUS_SCHEMES = {
    javascript = true, data = true, file = true, vbscript = true,
}

--- img src: relative URLs and http(s) are fine; anything with a dangerous
--- scheme is not.
local function is_safe_image_url(value)
    local scheme = url_scheme(value)
    if scheme == nil then
        return true
    end
    return scheme == "http" or scheme == "https"
end

--- a href: the contract allows http/https only (no relative links on a device
--- with no browser).
local function is_safe_link_url(value)
    local scheme = url_scheme(value)
    return scheme == "http" or scheme == "https"
end

--==========================================================================
-- CSS
--==========================================================================

-- Exact property names from the contract.
local ALLOWED_PROPERTIES = {
    color = true,
    background = true,
    ["text-align"] = true,
    width = true,
    height = true,
    ["line-height"] = true,
    ["white-space"] = true,
}

-- Contract families: font-*, margin*, padding*, border*.  `background` is also
-- a family in practice (background-color, background-repeat, ...), and its
-- url-carrying members are rejected by the value check below.
local ALLOWED_PROPERTY_PREFIXES = {
    "font-", "margin", "padding", "border", "background",
}

local function property_allowed(property)
    if ALLOWED_PROPERTIES[property] then
        return true
    end
    for index = 1, #ALLOWED_PROPERTY_PREFIXES do
        local prefix = ALLOWED_PROPERTY_PREFIXES[index]
        if property:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

--- Values that can pull in external resources or execute code.  Dropping the
--- whole declaration (not the property) is required: `background: url(x)`
--- would otherwise be kept as a useless empty rule that still fetches.
local function value_is_safe(value)
    local lowered = value:lower()
    if lowered:find("url%s*%(") then
        return false
    end
    if lowered:find("expression") then
        return false
    end
    if lowered:find("javascript:") then
        return false
    end
    -- A `</style` in a value could break out if this CSS is ever inlined.
    if lowered:find("</") then
        return false
    end
    return true
end

local function filter_declaration(declaration)
    local property, value = declaration:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
    if not property then
        return nil
    end
    property = property:lower()
    if value == "" or not property_allowed(property) then
        return nil
    end
    if not value_is_safe(value) then
        return nil
    end
    return property .. ": " .. value
end

--- Filter a bare declaration list (`color: red; font-size: 12px`).
local function filter_declaration_list(text)
    local out = {}
    for declaration in (text .. ";"):gmatch("([^;]-);") do
        local filtered = filter_declaration(declaration)
        if filtered then
            out[#out + 1] = filtered .. ";"
        end
    end
    return table.concat(out, "\n")
end

--- At-rule block headers we cannot let through: they either import another
--- stylesheet or are not real CSS.  `@media` / `@supports` / `@font-face` are
--- fine because their bodies go through the same declaration filter.
local UNSAFE_PRELUDE_PREFIXES = { "@import", "@charset", "@namespace" }

local function is_safe_prelude(prelude)
    if prelude == "" then
        return false
    end
    local lowered = prelude:lower()
    if lowered:find("url%s*%(") or lowered:find("expression") then
        return false
    end
    if lowered:find("</") then
        return false
    end
    for index = 1, #UNSAFE_PRELUDE_PREFIXES do
        local prefix = UNSAFE_PRELUDE_PREFIXES[index]
        if lowered:sub(1, #prefix) == prefix then
            return false
        end
    end
    return true
end

--- Filter a stylesheet, preserving selectors and block structure.
--
-- The walker keeps a brace depth so it never needs a regex for nesting: CSS is
-- not regular, and a naive `gsub("([^}]+){([^}]*)}")` breaks on @media blocks.
function M.css(raw)
    if type(raw) ~= "string" or raw == "" then
        return ""
    end

    -- Comments first: they can contain braces and quotes that would otherwise
    -- derail the walker.
    local css = raw:gsub("/%*.-%*/", "")
    css = css:gsub("/%*.*$", "") -- unterminated comment

    -- A bare declaration list is not a stylesheet, but accepting it makes the
    -- function usable for inline `style` attributes too.
    if not css:find("{", 1, true) and not css:find("}", 1, true) then
        return filter_declaration_list(css)
    end

    local out = {}
    local buffer = {}
    local depth = 0
    local skipping = false
    local skip_depth = 0
    local index = 1
    local length = #css

    local function take_buffer()
        local text = table.concat(buffer)
        buffer = {}
        return text
    end

    while index <= length do
        local char = css:sub(index, index)
        if char == "{" then
            local prelude = trim(take_buffer())
            if skipping then
                depth = depth + 1
            elseif is_safe_prelude(prelude) then
                out[#out + 1] = prelude .. " {"
                out[#out + 1] = "\n"
                depth = depth + 1
            else
                -- Skip the whole block: an unsafe @import/@charset or a
                -- selector we refuse cannot contribute anything useful.
                skipping = true
                skip_depth = depth
                depth = depth + 1
            end
        elseif char == "}" then
            if skipping then
                depth = depth - 1
                if depth <= skip_depth then
                    skipping = false
                    depth = math.max(depth, 0)
                end
            else
                if depth >= 1 then
                    local declaration = trim(take_buffer())
                    local filtered = filter_declaration(declaration)
                    if filtered then
                        out[#out + 1] = filtered .. ";"
                        out[#out + 1] = "\n"
                    end
                    depth = math.max(depth - 1, 0)
                    out[#out + 1] = "}\n"
                else
                    -- A stray closing brace; drop it so the output stays
                    -- balanced no matter how broken the input was.
                    depth = 0
                end
            end
            buffer = {}
        elseif char == ";" then
            if not skipping then
                if depth >= 1 then
                    local declaration = trim(take_buffer())
                    local filtered = filter_declaration(declaration)
                    if filtered then
                        out[#out + 1] = filtered .. ";"
                        out[#out + 1] = "\n"
                    end
                end
                -- Depth 0 statements are at-rules such as `@import url(...);`
                -- and never reach the output.
            end
            buffer = {}
        else
            if not skipping then
                buffer[#buffer + 1] = char
            end
        end
        index = index + 1
    end

    return table.concat(out)
end

--==========================================================================
-- HTML
--==========================================================================

--- Locate `</name ...>` starting at `from`.  Returns start and end (`>`)
--- positions or nil when the element is never closed.
local function find_closing_tag(lower, name, from)
    local needle = "</" .. name
    local position = from
    local length = #lower
    while position <= length do
        local start_pos = lower:find(needle, position, true)
        if not start_pos then
            return nil
        end
        local after = lower:sub(start_pos + #needle, start_pos + #needle)
        if after == "" or after == ">" or after:match("[%s/]") then
            local close_end = lower:find(">", start_pos + #needle, true)
            if not close_end then
                return nil
            end
            return start_pos, close_end
        end
        position = start_pos + #needle
    end
    return nil
end

--- Rebuild an allowed tag with only its whitelisted, sanitised attributes.
local function rebuild_tag(name, attributes_text)
    local allowed = ALLOWED_ATTRIBUTES[name]
    local parts = { "<", name }
    if allowed then
        local attributes = parse_attributes(attributes_text)
        for index = 1, #attributes do
            local attribute = attributes[index]
            local attribute_name = attribute.name
            local value = attribute.value
            local keep = nil
            if allowed[attribute_name] then
                if attribute_name == "style" then
                    local css = M.css(value)
                    if css ~= "" then
                        keep = css
                    end
                elseif attribute_name == "href" then
                    if is_safe_link_url(value) then
                        keep = value
                    end
                elseif attribute_name == "src" then
                    if is_safe_image_url(value) then
                        keep = value
                    end
                else
                    keep = value
                end
            end
            if keep ~= nil then
                parts[#parts + 1] = " "
                parts[#parts + 1] = attribute_name
                parts[#parts + 1] = '="'
                parts[#parts + 1] = escape_attribute(keep)
                parts[#parts + 1] = '"'
            end
        end
    end
    parts[#parts + 1] = ">"
    return table.concat(parts)
end

function M.html(raw)
    if type(raw) ~= "string" or raw == "" then
        return ""
    end

    local lower = raw:lower()
    local out = {}
    local position = 1
    local length = #raw

    while position <= length do
        local lt = raw:find("<", position, true)
        if not lt then
            out[#out + 1] = raw:sub(position)
            break
        end
        if lt > position then
            out[#out + 1] = raw:sub(position, lt - 1)
        end

        if raw:sub(lt, lt + 3) == "<!--" then
            local close = raw:find("-->", lt + 4, true)
            position = close and (close + 3) or (length + 1)
        elseif raw:sub(lt + 1, lt + 1) == "!" or raw:sub(lt + 1, lt + 1) == "?" then
            -- Doctype / processing instruction: nothing renderable inside.
            local close = raw:find(">", lt + 1, true)
            position = close and (close + 1) or (length + 1)
        else
            local gt = find_tag_end(raw, lt + 1)
            if not gt then
                -- A lone `<` with no tag end (plain text like "1 < 2").
                out[#out + 1] = raw:sub(lt)
                break
            end

            local name, closing, self_closing, attributes_text =
                parse_tag(raw, lt, gt)

            if not name then
                -- Not a tag after all; keep the `<` and rescan from after it.
                out[#out + 1] = "<"
                position = lt + 1
            elseif DROP_WITH_CONTENT[name] then
                if closing or self_closing then
                    position = gt + 1
                else
                    local _, close_end = find_closing_tag(lower, name, gt + 1)
                    -- An unclosed <script>/<style> swallows the rest: there is
                    -- no reliable way to find where its content ends.
                    position = close_end and (close_end + 1) or (length + 1)
                end
            elseif DROP_TAG_ONLY[name] then
                position = gt + 1
            elseif closing then
                if ALLOWED_TAGS[name] and not VOID_TAGS[name] then
                    out[#out + 1] = "</" .. name .. ">"
                end
                position = gt + 1
            else
                if ALLOWED_TAGS[name] then
                    out[#out + 1] = rebuild_tag(name, attributes_text)
                end
                position = gt + 1
            end
        end
    end

    return table.concat(out)
end

return M
