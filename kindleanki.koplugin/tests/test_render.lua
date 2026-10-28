-- Template evaluation tests.
--
-- Every rule in the render contract has at least one case here, including the
-- malformed inputs a synced collection can contain: unclosed sections,
-- mismatched closing tags, empty/whitespace fields, very long fields, and
-- multi-byte text.  Nothing in this file loads KOReader.

local Render = require("render.template")

local TYPE_FALLBACK = "<div>（输入型卡片已降级为自评）</div>"

--- Build a note type with a single template.
local function notetype_with(qfmt, afmt, opts)
    opts = opts or {}
    local names = opts.field_names or { "Front", "Back" }
    local fields = {}
    for index = 1, #names do
        fields[index] = { name = names[index] }
    end
    local templates = opts.templates or {
        { ord = 0, name = "Card 1", qfmt = qfmt, afmt = afmt },
    }
    return {
        kind = opts.kind or 0,
        css = opts.css or "",
        fields = fields,
        templates = templates,
    }
end

local function render(qfmt, afmt, field_values, opts)
    opts = opts or {}
    local notetype = notetype_with(qfmt, afmt, opts)
    local note = {
        fields = field_values,
        tags = opts.tags or "",
    }
    local card = { ord = opts.ord or 0 }
    local context = {
        deck_name = opts.deck_name or "",
        card_name = opts.card_name or "",
    }
    return Render.card_faces(notetype, note, card, context)
end

return {
    --======================================================================
    -- 1. Plain field substitution
    --======================================================================

    ["field values are emitted verbatim, not escaped"] = function()
        local faces = render("{{Front}}", "{{FrontSide}}", { "<b>粗体</b> & 「引用」" })
        assert(faces.question_html == "<b>粗体</b> & 「引用」", faces.question_html)
        assert(faces.answer_html == faces.question_html)
    end,

    ["text around and between fields keeps its order"] = function()
        local faces = render("1{{Front}}2{{Front}}3", "", { "X", "Y" })
        assert(faces.question_html == "1X2X3", faces.question_html)
    end,

    ["an unknown field name renders as empty"] = function()
        local faces = render("[{{Nope}}]", "", { "X" })
        assert(faces.question_html == "[]", faces.question_html)
        assert(faces.ok, "an unknown field is not a template error")
    end,

    ["a missing field list yields empty strings, not errors"] = function()
        local notetype = notetype_with("{{Front}}", "{{Back}}")
        local faces = Render.card_faces(notetype, {}, { ord = 0 }, {})
        assert(faces.question_html == "", faces.question_html)
        assert(faces.answer_html == "", faces.answer_html)
        assert(faces.ok)
    end,

    --======================================================================
    -- 2. Conditional sections
    --======================================================================

    ["positive section shows only for a non-empty field"] = function()
        local shown = render("{{#Front}}yes{{/Front}}!", "", { "Q" })
        assert(shown.question_html == "yes!", shown.question_html)
        local hidden = render("{{#Front}}yes{{/Front}}!", "", { "" })
        assert(hidden.question_html == "!", hidden.question_html)
    end,

    ["negative section shows only for an empty field"] = function()
        local hidden = render("{{^Front}}none{{/Front}}!", "", { "Q" })
        assert(hidden.question_html == "!", hidden.question_html)
        local shown = render("{{^Front}}none{{/Front}}!", "", { "" })
        assert(shown.question_html == "none!", shown.question_html)
    end,

    ["sections nest"] = function()
        local faces = render("{{#Front}}[{{#Back}}inner{{/Back}}]{{/Front}}", "", { "Q", "A" })
        assert(faces.question_html == "[inner]", faces.question_html)
        local inner_empty = render("{{#Front}}[{{#Back}}inner{{/Back}}]{{/Front}}", "", { "Q", "" })
        assert(inner_empty.question_html == "[]", inner_empty.question_html)
    end,

    ["whitespace and sound-only fields count as blank, markup does not"] = function()
        local blank = render("{{#Front}}x{{/Front}}", "", { "  \n\t " })
        assert(blank.question_html == "", blank.question_html)
        local silent = render("{{#Front}}x{{/Front}}", "", { "[sound:a.mp3]" })
        assert(silent.question_html == "", silent.question_html)
        local image = render("{{#Front}}x{{/Front}}", "", { '<img src="a.png">' })
        assert(image.question_html == "x", "an image-only field is not empty")
    end,

    ["unclosed section reports an error and falls back to the raw template"] = function()
        local faces = render("{{#Front}}oops{{Front}}", "", { "Q" })
        assert(faces.question_html == "{{#Front}}oops{{Front}}", faces.question_html)
        assert(not faces.ok)
        assert(#faces.errors == 1, "one error expected, got " .. #faces.errors)
        assert(faces.errors[1]:find("unclosed", 1, true), faces.errors[1])
    end,

    ["mismatched closing tag reports an error and falls back to the raw template"] = function()
        local faces = render("{{#Front}}a{{/Back}}", "", { "Q" })
        assert(faces.question_html == "{{#Front}}a{{/Back}}", faces.question_html)
        assert(not faces.ok)
        assert(faces.errors[1]:find("unmatched", 1, true), faces.errors[1])
    end,

    ["a broken answer template does not spoil the question face"] = function()
        local faces = render("Q{{Front}}", "{{#Back}}broken", { "Q", "A" })
        assert(faces.question_html == "QQ", faces.question_html)
        assert(faces.answer_html == "{{#Back}}broken", faces.answer_html)
        assert(not faces.ok)
    end,

    ["an unclosed mustache stays literal"] = function()
        local faces = render("a{{Front", "", { "Q" })
        assert(faces.question_html == "a{{Front", faces.question_html)
        assert(faces.ok)
    end,

    ["comments are dropped"] = function()
        local faces = render("a{{! a note }}b", "", { "Q" })
        assert(faces.question_html == "ab", faces.question_html)
    end,

    ["sections can test special fields"] = function()
        local with_tags = render("{{#Tags}}tagged{{/Tags}}", "", { "Q" }, { tags = "a b" })
        assert(with_tags.question_html == "tagged", with_tags.question_html)
        local without_tags = render("{{#Tags}}tagged{{/Tags}}", "", { "Q" }, { tags = "" })
        assert(without_tags.question_html == "", without_tags.question_html)
    end,

    --======================================================================
    -- 3. FrontSide
    --======================================================================

    ["FrontSide inserts the rendered question into the answer"] = function()
        local faces = render("Q:{{Front}}", "{{FrontSide}}|A:{{Back}}", { "q", "a" })
        assert(faces.question_html == "Q:q", faces.question_html)
        assert(faces.answer_html == "Q:q|A:a", faces.answer_html)
    end,

    ["FrontSide renders as nothing on the question face"] = function()
        local faces = render("a{{FrontSide}}b", "", { "q" })
        assert(faces.question_html == "ab", faces.question_html)
    end,

    --======================================================================
    -- 4. Cloze
    --======================================================================

    ["cloze hides the active deletion on the question face"] = function()
        local faces = render("{{cloze:Text}}", "{{cloze:Text}}",
            { "{{c1::one}} and {{c2::two}}" },
            { kind = 1, field_names = { "Text" }, ord = 0 })
        assert(not faces.question_html:find("one", 1, true), faces.question_html)
        assert(not faces.question_html:find("two", 1, true), faces.question_html)
        assert(faces.question_html == "[...] and [...]", faces.question_html)
    end,

    ["cloze bolds the active deletion on the answer face"] = function()
        local faces = render("{{cloze:Text}}", "{{cloze:Text}}",
            { "{{c1::one}} and {{c2::two}}" },
            { kind = 1, field_names = { "Text" }, ord = 0 })
        assert(faces.answer_html == "<b>one</b> and [...]", faces.answer_html)
        local second = render("{{cloze:Text}}", "{{cloze:Text}}",
            { "{{c1::one}} and {{c2::two}}" },
            { kind = 1, field_names = { "Text" }, ord = 1 })
        assert(second.answer_html == "[...] and <b>two</b>", second.answer_html)
    end,

    ["cloze hints use title on the answer face and parentheses on the question"] = function()
        local faces = render("{{cloze:Text}}", "{{cloze:Text}}",
            { "{{c1::one::first}} {{c2::two::second}}" },
            { kind = 1, field_names = { "Text" }, ord = 0 })
        assert(faces.answer_html == '<b><span title="first">one</span></b> [...]',
            faces.answer_html)
        -- The hint is the only help available before answering.
        assert(faces.question_html == "[...]（first） [...]", faces.question_html)
    end,

    ["cloze ignores a card whose ordinal has no deletion"] = function()
        local faces = render("{{cloze:Text}}", "{{cloze:Text}}",
            { "{{c1::one}}" },
            { kind = 1, field_names = { "Text" }, ord = 4 })
        assert(faces.question_html == "[...]", faces.question_html)
        assert(faces.answer_html == "[...]", faces.answer_html)
    end,

    --======================================================================
    -- 5. type: filter
    --======================================================================

    ["type filter degrades to the plain field plus a self-grade note"] = function()
        local faces = render("{{type:Front}}", "{{FrontSide}}", { "<b>答え</b>" })
        assert(faces.question_html == "<b>答え</b>" .. TYPE_FALLBACK, faces.question_html)
    end,

    --======================================================================
    -- 6. text: / hint: filters
    --======================================================================

    ["text filter removes tags and script bodies"] = function()
        local faces = render("{{text:Front}}", "", {
            "<b>粗体</b><br>下一行<script>alert(1)</script>",
        })
        assert(faces.question_html == "粗体 下一行", faces.question_html)
    end,

    ["hint filter shows the field name"] = function()
        local faces = render("{{hint:Back}}", "", { "q", "a" })
        assert(faces.question_html == "（提示：Back）", faces.question_html)
    end,

    --======================================================================
    -- 7. Special fields
    --======================================================================

    ["special fields resolve from the note and the context"] = function()
        local faces = render(
            "{{Tags}}|{{Deck}}|{{Subdeck}}|{{Card}}|{{Type}}", "",
            { "q", "a" },
            { tags = "tag1 tag2", deck_name = "日语::N5", card_name = "Card 1" })
        assert(faces.question_html == "tag1 tag2|日语::N5|N5|Card 1|Forward",
            faces.question_html)
    end,

    ["Type distinguishes cloze and reverse templates"] = function()
        local cloze = render("{{Type}}", "", { "q", "a" }, { kind = 1 })
        assert(cloze.question_html == "Cloze", cloze.question_html)
        local reverse = render("{{Type}}", "", { "q", "a" }, { ord = 1 })
        assert(reverse.question_html == "Reverse", reverse.question_html)
    end,

    ["Card falls back to the template name when the context is empty"] = function()
        local faces = render("{{Card}}", "", { "q" })
        assert(faces.question_html == "Card 1", faces.question_html)
    end,

    --======================================================================
    -- 8. Audio and images
    --======================================================================

    ["sound markers become an audio placeholder"] = function()
        local faces = render("{{Front}}", "", { "[sound:cat.mp3]" })
        assert(faces.question_html == "（音频）", faces.question_html)
    end,

    ["images are kept and recorded as media"] = function()
        local faces = render(
            '<img src="cat.png" alt="cat"><IMG SRC=\'dog.png\'>{{Front}}', "",
            { '<img src="bird.png">' })
        assert(faces.question_html:find('<img src="cat.png"', 1, true), faces.question_html)
        assert(faces.media["cat.png"], "cat.png is not in media")
        assert(faces.media["dog.png"], "dog.png is not in media")
        assert(faces.media["bird.png"], "bird.png from a field is not in media")
        assert(not faces.media["https://example.com/x.png"])
    end,

    ["remote and data images are not recorded as media"] = function()
        local faces = render(
            '<img src="https://example.com/x.png"><img src="data:image/png;base64,AA">',
            "", { "q" })
        local count = 0
        for _ in pairs(faces.media) do
            count = count + 1
        end
        assert(count == 0, "media table should be empty")
    end,

    --======================================================================
    -- 9. Unknown filters
    --======================================================================

    ["unknown filters render the field after the last colon"] = function()
        local tts = render("{{tts ja:Front}}", "", { "こんにちは" })
        assert(tts.question_html == "こんにちは", tts.question_html)
        local furigana = render("{{furigana:Front}}", "", { "漢字" })
        assert(furigana.question_html == "漢字", furigana.question_html)
        local chained = render("{{unknown:also:Front}}", "", { "X" })
        assert(chained.question_html == "X", chained.question_html)
        assert(tts.ok and furigana.ok and chained.ok, "unknown filters are not errors")
    end,

    --======================================================================
    -- 10. CSS handling
    --======================================================================

    ["css is returned as-is and never inlined into the faces"] = function()
        local css = ".card { color: red; }\n.cloze { font-weight: bold; }"
        local faces = render("<style>.x{color:blue}</style>{{Front}}", "", { "q" },
            { css = css })
        assert(faces.css == css, faces.css)
        assert(not faces.question_html:find("<style", 1, true), faces.question_html)
        assert(faces.question_html == "q", faces.question_html)
    end,

    --======================================================================
    -- Template selection
    --======================================================================

    ["the card ordinal selects the template"] = function()
        local templates = {
            { ord = 0, name = "Card 1", qfmt = "first", afmt = "first-a" },
            { ord = 1, name = "Card 2", qfmt = "second", afmt = "second-a" },
        }
        local notetype = notetype_with(nil, nil, { templates = templates })
        local faces = Render.card_faces(notetype, { fields = { "q", "a" } },
            { ord = 1 }, {})
        assert(faces.question_html == "second", faces.question_html)
        assert(faces.answer_html == "second-a", faces.answer_html)
    end,

    ["an unknown card ordinal falls back to the first template"] = function()
        local faces = render("{{Front}}", "", { "q" }, { ord = 9 })
        assert(faces.question_html == "q", faces.question_html)
    end,

    ["a template list with only a name renders empty faces"] = function()
        local notetype = {
            fields = { { name = "Front" } },
            templates = { { ord = 0, name = "Card 1" } },
        }
        local faces = Render.card_faces(notetype, { fields = { "q" } }, { ord = 0 }, {})
        assert(faces.question_html == "" and faces.answer_html == "")
        assert(faces.ok)
    end,

    --======================================================================
    -- Malformed / defensive input
    --======================================================================

    ["nil arguments produce an empty but usable result"] = function()
        local faces = Render.card_faces(nil, nil, nil, nil)
        assert(type(faces) == "table")
        assert(faces.question_html == "" and faces.answer_html == "")
        assert(type(faces.media) == "table" and faces.css == "")
    end,

    ["empty field values and empty templates are safe"] = function()
        local faces = render("", "", { "", "" })
        assert(faces.question_html == "" and faces.answer_html == "")
        assert(faces.ok)
    end,

    ["a very long field renders unchanged"] = function()
        local long_value = string.rep("長", 20000) .. "<b>" .. string.rep("x", 40000) .. "</b>"
        local faces = render("{{Front}}", "{{FrontSide}}", { long_value })
        assert(faces.question_html == long_value, "long field was altered")
        assert(faces.answer_html == long_value)
        assert(#faces.media == 0)
    end,

    ["multi-byte text survives byte for byte"] = function()
        local value = "日本語：こんにちは、中文：你好 🎌"
        local faces = render("{{Front}}", "{{FrontSide}}", { value })
        assert(faces.question_html == value, faces.question_html)
        assert(faces.answer_html == value, faces.answer_html)
    end,

    ["a field value that looks like a tag is not evaluated"] = function()
        local faces = render("{{Front}}", "", { "{{#Back}}not a section{{/Back}}" })
        assert(faces.question_html == "{{#Back}}not a section{{/Back}}",
            faces.question_html)
        assert(faces.ok)
    end,
}
