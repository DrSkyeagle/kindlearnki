-- Locks the approved design tokens.
--
-- These cases are the contract between the design and the two self-drawn
-- screens: if a token drifts, this file fails before anything reaches the
-- device.  They run on a bare LuaJIT (no KOReader), which is also why
-- `ui/tokens.lua` is not allowed to require KOReader at load time.

-- Snapshot before the first require: a module that leaks a global here would
-- silently shadow something in KOReader's frontend, where `_G` is shared.
local globals_before = {}
for name in pairs(_G) do
    globals_before[name] = true
end

local Tokens = require("ui.tokens")

local leaked_globals = {}
for name in pairs(_G) do
    if not globals_before[name] then
        leaked_globals[#leaked_globals + 1] = name
    end
end

-- A fake `ui/font` module.  `fail[name]` makes that face raise, exactly how a
-- build without the serif family behaves (KOReader's Font:getFace() raises from
-- FreeType when the file is missing).
local function fake_font(fail)
    return {
        getFace = function(_, name, size)
            if fail and fail[name] then
                error("font not found: " .. tostring(name), 0)
            end
            return { name = name, size = size, orig_size = size }
        end,
    }
end

local function injected_require(font, log)
    return {
        require_fn = function(module)
            assert(module == "ui/font", "unexpected require: " .. tostring(module))
            return font
        end,
        log_fn = log or function() end,
    }
end

return {
    ["the page is white and the ink is #111111"] = function()
        assert(Tokens.color.paper == "#FFFFFF", Tokens.color.paper)
        assert(Tokens.color.ink == "#111111", Tokens.color.ink)
    end,

    ["the design's two inks parse to usable bytes"] = function()
        local r, g, b = Tokens.hex_to_rgb(Tokens.color.paper)
        assert(r == 255 and g == 255 and b == 255, string.format("%d,%d,%d", r, g, b))
        local ir, ig, ib = Tokens.hex_to_rgb(Tokens.color.ink)
        assert(ir == 17 and ig == 17 and ib == 17, string.format("%d,%d,%d", ir, ig, ib))
    end,

    ["a malformed colour token degrades to ink instead of crashing"] = function()
        local r, g, b = Tokens.hex_to_rgb("not-a-colour")
        assert(r == 17 and g == 17 and b == 17)
        local nr, ng, nb = Tokens.hex_to_rgb(nil)
        assert(nr == 17 and ng == 17 and nb == 17)
    end,

    ["body copy is 20 on the serif face, falling back to cfont"] = function()
        assert(Tokens.font.body == 20, tostring(Tokens.font.body))
        assert(Tokens.font.family == "tfont", Tokens.font.family)
        assert(Tokens.font.fallback == "cfont", Tokens.font.fallback)
    end,

    ["line pitch is 1.65, i.e. 0.65 extra for TextBoxWidget"] = function()
        assert(Tokens.line_height_extra == 0.65, tostring(Tokens.line_height_extra))
        assert(Tokens.font.line_height_extra == Tokens.line_height_extra)
        assert(Tokens.font.line_height == 1.65, tostring(Tokens.font.line_height))
        -- Both numbers are locked, and they must stay one and the same: 1.65 in
        -- the design is "1 + 0.65" for anything that takes an extra line height.
        local extra = Tokens.font.line_height - 1
        assert(math.abs(extra - Tokens.line_height_extra) < 1e-9,
            string.format("line_height %s and extra %s disagree",
                tostring(Tokens.font.line_height), tostring(Tokens.line_height_extra)))
    end,

    ["the visual margin is 10"] = function()
        assert(Tokens.space.margin == 10, tostring(Tokens.space.margin))
    end,

    ["there are exactly four ratings, in AnkiDroid order"] = function()
        local expected = { "重来", "困难", "记住", "太简单" }
        assert(#Tokens.rating_labels == 4, tostring(#Tokens.rating_labels))
        for index = 1, 4 do
            assert(Tokens.rating_labels[index] == expected[index],
                string.format("rating %d is %q, expected %q", index,
                    tostring(Tokens.rating_labels[index]), expected[index]))
        end
        assert(#Tokens.rating_values == 4)
        for index = 1, 4 do
            assert(Tokens.rating_values[index] == index,
                string.format("rating value %d is %s", index,
                    tostring(Tokens.rating_values[index])))
        end
    end,

    ["progress reads 已 N · 余 M, never N/M"] = function()
        assert(Tokens.progress_text(12, 55) == "已 12 · 余 55",
            Tokens.progress_text(12, 55))
        assert(Tokens.progress_text(0, 0) == "已 0 · 余 0",
            Tokens.progress_text(0, 0))
        -- Missing/garbage counters must not print "nil" on the study screen.
        assert(Tokens.progress_text(nil, nil) == "已 0 · 余 0",
            Tokens.progress_text(nil, nil))
        assert(Tokens.progress_text(12, 55):find("/", 1, true) == nil)
    end,

    ["the all-decks footer carries the total"] = function()
        assert(Tokens.all_decks_text(484) == "全部牌组一起复习 484 →",
            Tokens.all_decks_text(484))
        assert(Tokens.all_decks_text(0) == "全部牌组一起复习 0 →",
            Tokens.all_decks_text(0))
        assert(Tokens.all_decks_text(nil) == "全部牌组一起复习 0 →",
            Tokens.all_decks_text(nil))
    end,

    ["the new/learning/review split reads 新 n · 学 n · 复 n"] = function()
        local text = Tokens.counts_text({ new = 12, learning = 3, review = 55 })
        assert(text == "新 12 · 学 3 · 复 55", text)
        assert(Tokens.counts_text(nil) == "新 0 · 学 0 · 复 0", Tokens.counts_text(nil))
        local total = Tokens.count_total({ new = 12, learning = 3, review = 55 })
        assert(total == 70, tostring(total))
        assert(Tokens.count_total(nil) == 0)
    end,

    ["the hidden-deck note names how many decks did not fit"] = function()
        assert(Tokens.hidden_decks_text(3) == "另有 3 个牌组",
            Tokens.hidden_decks_text(3))
        assert(Tokens.hidden_decks_text(nil) == "另有 0 个牌组",
            Tokens.hidden_decks_text(nil))
    end,

    ["fixed copy for the answer bar and the bottom row"] = function()
        assert(Tokens.action_text == "显示答案", Tokens.action_text)
        assert(Tokens.menu_text == "菜单", Tokens.menu_text)
        assert(Tokens.sync_text == "同步", Tokens.sync_text)
        assert(Tokens.exit_text == "×", Tokens.exit_text)
    end,

    ["the exit hot zone is at least the 44dp minimum"] = function()
        assert(Tokens.size.exit_hit >= 44, tostring(Tokens.size.exit_hit))
        -- The action bar doubles as the rating row, so it has to hold a 44dp
        -- tall touch target too.
        assert(Tokens.size.action_bar >= 44, tostring(Tokens.size.action_bar))
    end,

    ["face() uses the serif face when the host has it"] = function()
        local face = Tokens.face(20, injected_require(fake_font()))
        assert(type(face) == "table", tostring(face))
        assert(face.name == "tfont", tostring(face.name))
        assert(face.orig_size == 20, tostring(face.orig_size))
    end,

    ["face() falls back to cfont and logs why when the serif face is missing"] = function()
        local logged = {}
        local face = Tokens.face(20, injected_require(fake_font({ tfont = true }), function(message)
            logged[#logged + 1] = tostring(message)
        end))
        assert(type(face) == "table", tostring(face))
        assert(face.name == "cfont", tostring(face.name))
        assert(#logged >= 1, "the fallback must be logged, not swallowed")
        assert(logged[1]:find("tfont", 1, true), logged[1])
        assert(logged[1]:find("cfont", 1, true), logged[1])
    end,

    ["face() gives up quietly when there is no font engine at all"] = function()
        local logged = {}
        local face = Tokens.face(20, {
            require_fn = function()
                error("no KOReader here", 0)
            end,
            log_fn = function(message)
                logged[#logged + 1] = tostring(message)
            end,
        })
        assert(face == nil, tostring(face))
        assert(#logged == 1, "expected exactly one log line, got " .. tostring(#logged))
        assert(logged[1]:find("ui/font", 1, true), logged[1])
    end,

    ["face() returns nil when even the fallback face fails"] = function()
        local face = Tokens.face(20, injected_require(fake_font({ tfont = true, cfont = true })))
        assert(face == nil, tostring(face))
    end,

    ["requiring the tokens leaks no globals"] = function()
        assert(#leaked_globals == 0,
            "ui/tokens.lua leaked global(s): " .. table.concat(leaked_globals, ", "))
    end,
}
