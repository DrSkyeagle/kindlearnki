-- Sanitizer tests.
--
-- The contract's rules are enumerated here one by one: tag whitelist, removal
-- with content, unwrapping unknown tags, per-element attribute whitelist,
-- URL schemes, and the CSS property/value filter.  Malformed markup is covered
-- because collections synced from AnkiDroid 2.16.5 do contain it.

local Sanitize = require("render.sanitize")

return {
    --======================================================================
    -- Tag whitelist
    --======================================================================

    ["every whitelisted tag survives"] = function()
        local pairs_of_tags = {
            { "b", "i" }, { "u", "s" }, { "em", "strong" },
            { "div", "p" }, { "span", "blockquote" },
            { "table", "thead" }, { "tbody", "tr" }, { "td", "th" },
            { "ul", "ol" }, { "li", "h1" }, { "h2", "h3" }, { "h4", "h5" },
            { "h6", "pre" }, { "code", "font" }, { "a", "sub" },
            { "sup", "center" },
        }
        for _, pair in ipairs(pairs_of_tags) do
            local html = Sanitize.html(string.format("<%s>x</%s><%s>y</%s>",
                pair[1], pair[1], pair[2], pair[2]))
            assert(html:find("<" .. pair[1] .. ">", 1, true), pair[1] .. " was dropped: " .. html)
            assert(html:find("</" .. pair[1] .. ">", 1, true), pair[1] .. " close was dropped")
            assert(html:find("<" .. pair[2] .. ">", 1, true), pair[2] .. " was dropped")
        end
    end,

    ["void tags are kept without a closing tag"] = function()
        local html = Sanitize.html("a<br>b<hr>c<img src=\"x.png\">")
        assert(html == 'a<br>b<hr>c<img src="x.png">', html)
    end,

    ["uppercase tags are normalized to lowercase"] = function()
        local html = Sanitize.html("<B>bold</B>")
        assert(html == "<b>bold</b>", html)
    end,

    --======================================================================
    -- Elements removed together with their content
    --======================================================================

    ["script is removed with its content"] = function()
        assert(Sanitize.html("<script>alert(1)</script>ok") == "ok")
        -- Multiple scripts: a greedy match would eat the text between them.
        assert(Sanitize.html("a<script>x</script>b<script>y</script>c") == "abc")
        assert(Sanitize.html("<SCRIPT type='text/javascript'>x</SCRIPT>ok") == "ok")
        -- An unclosed script swallows the rest rather than leaking source.
        assert(Sanitize.html("a<script>x = 1") == "a")
    end,

    ["style is removed with its content"] = function()
        assert(Sanitize.html("a<style>.x{color:red}</style>b") == "ab")
        assert(Sanitize.html("<STYLE>.x{}</STYLE>ok") == "ok")
    end,

    ["container elements are removed with their content"] = function()
        local containers = { "iframe", "object", "form", "audio", "video", "svg", "math" }
        for _, name in ipairs(containers) do
            local html = Sanitize.html(
                string.format("a<%s><b>inner</b></%s>b", name, name))
            assert(html == "ab", name .. " leaked content: " .. html)
        end
    end,

    ["void blocklisted tags are removed but keep their neighbours"] = function()
        local html = Sanitize.html(
            'a<input type="text">b<link rel="x">c<meta charset="utf-8">d<embed src="x">e')
        assert(html == "abcde", html)
    end,

    --======================================================================
    -- Unknown tags
    --======================================================================

    ["unknown tags lose the tag but keep the text"] = function()
        local html = Sanitize.html("<custom-tag foo='bar'>text</custom-tag><foo>t</foo>")
        assert(html == "textt", html)
        local closing = Sanitize.html("a</unknown>b")
        assert(closing == "ab", closing)
    end,

    ["text that merely looks like a tag is preserved"] = function()
        assert(Sanitize.html("1 < 2 > 0") == "1 < 2 > 0")
        assert(Sanitize.html("a < b") == "a < b")
        assert(Sanitize.html("") == "")
        assert(Sanitize.html(nil) == "")
    end,

    --======================================================================
    -- Attribute whitelist
    --======================================================================

    ["img keeps only src/alt/width/height and drops handlers"] = function()
        local html = Sanitize.html(
            '<img src="cat.png" alt="cat" width="100" height="200" '
            .. 'onerror="evil()" onload="x" class="c" style="z-index:1">')
        assert(html == '<img src="cat.png" alt="cat" width="100" height="200">', html)
    end,

    ["font keeps only color/face/size"] = function()
        local html = Sanitize.html('<font color="red" face="serif" size="3" class="c">t</font>')
        assert(html == '<font color="red" face="serif" size="3">t</font>', html)
    end,

    ["td and th keep only colspan/rowspan"] = function()
        local html = Sanitize.html('<td colspan="2" rowspan="3" class="c">c</td>')
        assert(html == '<td colspan="2" rowspan="3">c</td>', html)
        local header = Sanitize.html('<th colspan="1" style="color:red">h</th>')
        assert(header == '<th colspan="1">h</th>', header)
    end,

    ["div/p/span keep only a filtered style attribute"] = function()
        local html = Sanitize.html(
            '<div class="card" style="color:red;position:absolute;margin-top:2px">d</div>')
        assert(html == '<div style="color: red; margin-top: 2px;">d</div>', html)
        assert(Sanitize.html('<p align="center">p</p>') == "<p>p</p>")
        assert(Sanitize.html('<span class="cloze">s</span>') == "<span>s</span>")
    end,

    ["all event handler attributes are dropped"] = function()
        local html = Sanitize.html(
            '<div onclick="a()" onmouseover="b()" onfocus="c()">x</div>'
            .. '<b onload="d()">y</b>'
            .. '<table onerror="e()"><tr onx="f()"><td ony="g()">z</td></tr></table>')
        assert(not html:find("onclick", 1, true), html)
        assert(not html:find("onload", 1, true), html)
        assert(not html:find("onmouseover", 1, true), html)
        assert(not html:find("onfocus", 1, true), html)
        assert(not html:find("onerror", 1, true), html)
        assert(not html:find("onx", 1, true), html)
        assert(not html:find("ony", 1, true), html)
    end,

    ["attributes with unquoted and single-quoted values are handled"] = function()
        local html = Sanitize.html("<img src=a.png alt='x'>")
        assert(html == '<img src="a.png" alt="x">', html)
    end,

    ["a quoted '>' inside an attribute does not truncate the tag"] = function()
        -- The `>` is escaped on output; what matters is that the tag was not
        -- split at it, leaving the browser to repair broken markup.
        local html = Sanitize.html('<img src="a>b.png" alt="x">')
        assert(html == '<img src="a&gt;b.png" alt="x">', html)
    end,

    --======================================================================
    -- URLs
    --======================================================================

    ["javascript/data/file/vbscript URLs are dropped"] = function()
        local cases = {
            '<a href="javascript:alert(1)">x</a>',
            '<a href="JaVaScRiPt:alert(1)">x</a>',
            '<a href=" javascript:alert(1)">x</a>',
            '<a href="jav&#x61;script:alert(1)">x</a>',
            '<a href="data:text/html;base64,AA">x</a>',
            '<a href="file:///etc/passwd">x</a>',
            '<a href="vbscript:msgbox(1)">x</a>',
        }
        for _, html in ipairs(cases) do
            local sanitized = Sanitize.html(html)
            assert(sanitized == "<a>x</a>", html .. " -> " .. sanitized)
        end
    end,

    ["http and https links are kept"] = function()
        local html = Sanitize.html('<a href="https://example.com/a?b=1&amp;c=2">x</a>')
        assert(html == '<a href="https://example.com/a?b=1&amp;c=2">x</a>', html)
        assert(Sanitize.html('<a href="http://example.com">x</a>')
            == '<a href="http://example.com">x</a>')
    end,

    ["relative links are dropped because only http/https is allowed"] = function()
        local html = Sanitize.html('<a href="/local/page">x</a><a href="#anchor">y</a>')
        assert(html == "<a>x</a><a>y</a>", html)
    end,

    ["dangerous image URLs are dropped, local and remote images are kept"] = function()
        local html = Sanitize.html(
            '<img src="cat.png"><img src="../media/dog.png">'
            .. '<img src="https://example.com/x.png">'
            .. '<img src="data:image/png;base64,AA">'
            .. '<img src="javascript:alert(1)">'
            .. '<img src="file:///tmp/x.png">')
        assert(html:find('<img src="cat.png">', 1, true), html)
        assert(html:find('<img src="../media/dog.png">', 1, true), html)
        assert(html:find('<img src="https://example.com/x.png">', 1, true), html)
        assert(not html:find("data:", 1, true), html)
        assert(not html:find("javascript:", 1, true), html)
        assert(not html:find("file:", 1, true), html)
    end,

    --======================================================================
    -- CSS
    --======================================================================

    ["css keeps only the allowed property families"] = function()
        local css = Sanitize.css(table.concat({
            ".card {",
            "  color: red;",
            "  background-color: blue;",
            "  font-size: 20px;",
            "  font-family: serif;",
            "  margin: 0 auto;",
            "  margin-top: 2px;",
            "  padding: 1em;",
            "  border: 1px solid #000;",
            "  border-radius: 2px;",
            "  text-align: center;",
            "  width: 100%;",
            "  height: 2em;",
            "  line-height: 1.4;",
            "  white-space: pre-wrap;",
            "  position: absolute;",
            "  display: none;",
            "  z-index: 3;",
            "}",
        }, "\n"))
        assert(css:find("color: red;", 1, true), css)
        assert(css:find("background-color: blue;", 1, true), css)
        assert(css:find("font-size: 20px;", 1, true), css)
        assert(css:find("font-family: serif;", 1, true), css)
        assert(css:find("margin-top: 2px;", 1, true), css)
        assert(css:find("border-radius: 2px;", 1, true), css)
        assert(css:find("white-space: pre-wrap;", 1, true), css)
        assert(not css:find("position", 1, true), css)
        assert(not css:find("display", 1, true), css)
        assert(not css:find("z-index", 1, true), css)
    end,

    ["css declarations with url( or expression are dropped entirely"] = function()
        local css = Sanitize.css(table.concat({
            ".card {",
            "  background: url(cat.png) no-repeat;",
            "  background-image: url('cat.png');",
            "  behavior: expression(alert(1));",
            "  color: green;",
            "}",
        }, "\n"))
        assert(not css:find("url", 1, true), css)
        assert(not css:find("expression", 1, true), css)
        assert(css:find("color: green;", 1, true), css)
    end,

    ["css comments are removed"] = function()
        local css = Sanitize.css("/* a comment with { braces } */ .card { color: blue; }")
        assert(not css:find("comment", 1, true), css)
        assert(css:find("color: blue;", 1, true), css)
    end,

    ["css keeps @media structure and filters nested declarations"] = function()
        local css = Sanitize.css(
            "@media screen { .card { color: red; position: absolute; } }")
        assert(css:find("@media screen {", 1, true), css)
        assert(css:find("color: red;", 1, true), css)
        assert(not css:find("position", 1, true), css)
        local braces = 0
        for _ in css:gmatch("{") do
            braces = braces + 1
        end
        assert(braces == 2, "expected two opening braces, got " .. braces)
    end,

    ["css strips unsafe at-rules"] = function()
        local css = Sanitize.css(
            '@import url("evil.css");\n@charset "utf-8";\n.card { color: red; }')
        assert(not css:find("@import", 1, true), css)
        assert(not css:find("@charset", 1, true), css)
        assert(css:find("color: red;", 1, true), css)
    end,

    ["css accepts a bare declaration list"] = function()
        local css = Sanitize.css("color: red; position: absolute; margin: 0")
        assert(css:find("color: red;", 1, true), css)
        assert(css:find("margin: 0;", 1, true), css)
        assert(not css:find("position", 1, true), css)
    end,

    ["css is safe on empty and malformed input"] = function()
        assert(Sanitize.css(nil) == "")
        assert(Sanitize.css("") == "")
        assert(Sanitize.css("}}}") == "")
        assert(Sanitize.css("/* unterminated") == "")
        assert(Sanitize.css(".a{") == ".a {\n")
    end,

    ["style attributes use filtered single-line css"] = function()
        local html = Sanitize.html(
            '<span style="white-space: pre-wrap; background: url(x); color: #333">s</span>')
        assert(html == '<span style="white-space: pre-wrap; color: #333;">s</span>', html)
        assert(not html:find("url", 1, true), html)
    end,

    --======================================================================
    -- Malformed input / robustness
    --======================================================================

    ["comments and doctypes are removed"] = function()
        assert(Sanitize.html("a<!-- <script>x</script> -->b") == "ab")
        assert(Sanitize.html("<!DOCTYPE html><p>x</p>") == "<p>x</p>")
    end,

    ["malformed markup does not raise"] = function()
        assert(Sanitize.html("<b>unclosed <i>x") == "<b>unclosed <i>x")
        -- A bare `<>`/`</>` is not a tag; keep it as text rather than eating it.
        assert(Sanitize.html("<>") == "<>")
        assert(Sanitize.html("a<b") == "a<b")
        assert(Sanitize.html("</>") == "</>")
        assert(Sanitize.html("<!-- unclosed") == "")
    end,

    ["utf-8 text survives byte for byte"] = function()
        local html = Sanitize.html("<b>日本語のテキスト</b>与中文")
        assert(html == "<b>日本語のテキスト</b>与中文", html)
    end,

    ["plain text is passed through untouched"] = function()
        local text = "普通の文章 with spaces & symbols: 1+1=2"
        assert(Sanitize.html(text) == text)
    end,

    ["nested blocklisted elements are removed completely"] = function()
        local html = Sanitize.html("keep<div><script>a</script><style>b</style></div>end")
        assert(html == "keep<div></div>end", html)
    end,
}
