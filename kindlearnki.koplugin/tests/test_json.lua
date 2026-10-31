-- JSON codec tests: the wire rules the sync layer depends on.
--
-- The "python interop" expectations are hardcoded `json.dumps` outputs (the
-- spacing/escaping python actually produces), so the suite stays runnable on a
-- bare Windows box while still locking the contract down.

local json = require("sync.json")
local Helpers = require("helpers")

local function fixture(name)
    return Helpers.read("tests/fixtures/" .. name)
end

local function rejects(fn, needle)
    local ok, err = pcall(fn)
    assert(not ok, "expected an error")
    assert(type(err) == "string" and err:find("json", 1, true),
        "error should be tagged as json: " .. tostring(err))
    if needle then
        assert(err:find(needle, 1, true), "expected '" .. needle .. "' in: " .. err)
    end
end

return {
    ["encode scalars"] = function()
        assert(json.encode(true) == "true")
        assert(json.encode(false) == "false")
        assert(json.encode(0) == "0")
        assert(json.encode(-17) == "-17")
        assert(json.encode("hi") == '"hi"')
        assert(json.encode(json.null) == "null")
        assert(json.encode(1790701395200) == "1790701395200")
        assert(json.encode(9007199254740991) == "9007199254740991")
    end,

    ["encode arrays, objects and empty tables"] = function()
        assert(json.encode({ 1, 2, 3 }) == "[1,2,3]")
        assert(json.encode({ "a", "b" }) == '["a","b"]')
        assert(json.encode({}) == "{}", "empty table defaults to an object")
        assert(json.encode(json.array()) == "[]")
        assert(json.encode(json.array{}) == "[]")
        assert(json.encode(json.object()) == "{}")
        assert(json.encode({ a = 1 }) == '{"a":1}')
        -- Holes mean object: an array with a gap cannot round-trip.
        assert(json.encode({ [1] = "x", [3] = "y" }) == '{"1":"x","3":"y"}')
        assert(json.encode({ 1, 2, { 3, 4 } }) == "[1,2,[3,4]]")
        assert(json.encode({ a = { b = {} } }) == '{"a":{"b":{}}}')
        assert(json.encode({ a = json.array() }) == '{"a":[]}')
    end,

    ["encode escapes control characters and keeps UTF-8 verbatim"] = function()
        -- 0x1F is anki's field separator and is illegal raw inside JSON.
        assert(json.encode("a\31b") == '"a\\u001fb"')
        assert(json.encode("tab\there") == '"tab\\there"')
        assert(json.encode("nl\nhere") == '"nl\\nhere"')
        assert(json.encode("cr\rhere") == '"cr\\rhere"')
        assert(json.encode('quote"back\\slash') == '"quote\\"back\\\\slash"')
        -- Non-ASCII must pass through, not become \uXXXX.
        assert(json.encode("中文") == '"中文"')
        assert(json.encode("日本語のノート") == '"日本語のノート"')
        assert(json.encode("emoji 😀") == '"emoji 😀"')
        assert(not json.encode("中文"):find("\\u", 1, true))
    end,

    ["encode rejects NaN and infinities"] = function()
        rejects(function()
            return json.encode(0 / 0)
        end)
        rejects(function()
            return json.encode(math.huge)
        end)
        rejects(function()
            return json.encode(-math.huge)
        end)
        rejects(function()
            return json.encode({ value = math.huge })
        end)
    end,

    ["encode floats stays parseable and compact"] = function()
        assert(json.encode(1.5) == "1.5")
        assert(json.encode(0.1) == "0.1")
        assert(json.encode(-0.25) == "-0.25")
        assert(json.encode(1e-5) == "1e-05")
        local third = 1 / 3
        assert(tonumber(json.encode(third)) == third, "float must round-trip")
        local big = 1e300
        assert(tonumber(json.encode(big)) == big)
        for _, value in ipairs({ 0.1, 1e-7, 123456789.125, 1e17 }) do
            assert(tonumber(json.encode(value)) == value,
                "not round-tripping: " .. tostring(value))
        end
    end,

    ["decode scalars, containers and null"] = function()
        assert(json.decode("true") == true)
        assert(json.decode("false") == false)
        assert(json.decode("null") == nil)
        assert(json.decode("1790701395200") == 1790701395200)
        assert(json.decode("-17") == -17)
        assert(json.decode("1.5") == 1.5)
        assert(json.decode("1e3") == 1000)
        assert(json.decode('"x"') == "x")
        assert(json.decode("  [ 1 , 2 ]  ")[2] == 2)
        local value = json.decode('{"a":[1,2,{"b":null}],"c":""}')
        assert(value.a[1] == 1 and value.a[2] == 2)
        assert(value.a[3].b == nil)
        assert(value.c == "")
        assert(#json.decode("[]") == 0)
        assert(next(json.decode("{}")) == nil)
    end,

    ["decode \\u escapes and surrogate pairs"] = function()
        assert(json.decode('"nfront\\u001fnback"') == "nfront\31nback")
        assert(json.decode('"\\u4e2d\\u6587"') == "中文")
        assert(json.decode('"\\ud83d\\ude00"') == "\240\159\152\128")
        -- A lone surrogate is replaced, not fatal: one bad code point in a
        -- note field must not abort a whole sync.
        assert(json.decode('"\\ud83d"') == "\239\191\189")
        assert(json.decode('"\\/"') == "/")
    end,

    ["decode keeps array identity across re-encoding"] = function()
        assert(json.encode(json.decode("[]")) == "[]")
        assert(json.encode(json.decode("{}")) == "{}")
        assert(json.encode(json.decode("[[],{}]")) == "[[],{}]")
        -- A null in the middle keeps later elements at their positions.
        local mixed = json.decode("[1,null,3]")
        assert(mixed[1] == 1 and mixed[2] == nil and mixed[3] == 3)
        assert(json.encode(mixed) == "[1,null,3]")
    end,

    ["decode rejects malformed documents"] = function()
        rejects(function()
            json.decode("{")
        end)
        rejects(function()
            json.decode('"abc')
        end)
        rejects(function()
            json.decode("[1,]")
        end)
        rejects(function()
            json.decode('{"a":1,}')
        end)
        rejects(function()
            json.decode("1 2")
        end)
        rejects(function()
            json.decode("tru")
        end)
        rejects(function()
            json.decode('"\\q"')
        end)
        rejects(function()
            json.decode("1e")
        end)
        rejects(function()
            json.decode("")
        end)
    end,

    ["values round-trip through encode/decode"] = function()
        local cases = {
            { 1, 2, 3 },
            { client = { { 0, 0, 0 }, 5, 5, 2, 0, 6, 4, 1 } },
            { a = 1, b = { 2, 3 }, c = "x\31y" },
            { done = true, cards = json.array(), notes = json.array() },
            { data = "{}", flags = 0, empty = json.object() },
            "中文 field\31value",
            0,
            -1234567890123,
        }
        for _, case in ipairs(cases) do
            local encoded = json.encode(case)
            local decoded = json.decode(encoded)
            assert(json.encode(decoded) == encoded,
                "round trip mismatch: " .. encoded)
        end
    end,

    ["encodes what python json.dumps produced (hardcoded interop)"] = function()
        -- json.dumps(..., ensure_ascii=False) output, spaces included.
        local python_object = '{"a": 1, "b": [true, false, null], '
            .. '"c": "中文", "d": 1.5, "e": {"f": []}}'
        local value = json.decode(python_object)
        assert(value.a == 1 and value.b[1] == true and value.b[3] == nil)
        assert(value.c == "中文" and value.d == 1.5)
        assert(#value.e.f == 0)
        -- Our encoder emits the compact form with sorted keys; that string is
        -- what a later `json.loads` on the python side parses.
        assert(json.encode(value)
            == '{"a":1,"b":[true,false,null],"c":"中文","d":1.5,"e":{"f":[]}}')

        -- json.dumps default (ensure_ascii=True) escaped the Chinese text.
        assert(json.encode(json.decode('{"x": "\\u4e2d\\u6587"}'))
            == '{"x":"中文"}')
        assert(json.encode(json.decode('["\\u65e5\\u672c\\u8a9e"]'))
            == '["日本語"]')
        -- python prints 1e-05 for this value; either spelling parses.
        assert(tonumber(json.encode(json.decode("1e-05"))) == 1e-05)
    end,

    ["decodes a captured applyChunk request body"] = function()
        local text = fixture("ankiweb_applychunk_req.json")
        local request = json.decode(text)
        assert(request.chunk.done == true)
        assert(#request.chunk.cards == 1)
        assert(#request.chunk.cards[1] == 18, "cards are 18 positional fields")
        assert(request.chunk.cards[1][18] == "{}")
        assert(#request.chunk.notes == 1)
        assert(#request.chunk.notes[1] == 11, "notes are 11 positional fields")
        assert(request.chunk.notes[1][7] == "nfront\31nback")
        assert(request.chunk.notes[1][8] == "" and request.chunk.notes[1][9] == "")

        -- Re-encoding must keep the 0x1F separator escaped (it is illegal raw
        -- JSON and the peer would see a malformed body).
        local encoded = json.encode(request)
        assert(encoded:find("\\u001f", 1, true), "0x1F must stay escaped")
        local again = json.decode(encoded)
        assert(again.chunk.notes[1][7] == "nfront\31nback")
        assert(#again.chunk.cards[1] == 18)
    end,
}
