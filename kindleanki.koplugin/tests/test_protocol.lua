-- Protocol codec tests: constants, positional row arrays, request bodies.
--
-- These lock the *wire shape* only. The sync bookkeeping (which rows to send,
-- usn rewriting, sanity comparison) belongs to the later orchestration layer.

local json = require("sync.json")
local protocol = require("sync.protocol")

local function eq(actual, expected, label)
    assert(actual == expected,
        string.format("%s: expected %s, got %s", label or "value",
            tostring(expected), tostring(actual)))
end

local function encode(value)
    return json.encode(value)
end

local FULL_CARD = {
    id = 1790701395009,
    nid = 1790701395009,
    did = 1,
    ord = 2,
    mod = 1790701395,
    usn = -1,
    type = 0,
    queue = 0,
    due = 1,
    ivl = 0,
    factor = 0,
    reps = 0,
    lapses = 0,
    left = 0,
    odue = 0,
    odid = 0,
    flags = 0,
    data = "{}",
}

local FULL_NOTE = {
    id = 1790701395009,
    guid = "A+prSh9/iM",
    mid = 1790701394569,
    mod = 1790701395,
    usn = -1,
    tags = " x ",
    flds = "nfront\31nback",
    sfld = "42",
    csum = 424242,
    flags = 0,
    data = "",
}

local FULL_REVLOG = {
    id = 1790701395100,
    cid = 1790701395009,
    usn = -1,
    ease = 3,
    ivl = 10,
    lastIvl = 1,
    factor = 2500,
    time = 12345,
    type = 1,
}

return {
    ["constants match sync protocol v11"] = function()
        eq(protocol.VERSION, "0.1.0-dev")
        eq(protocol.ENDPOINT_DEFAULT, "https://sync.ankiweb.net/")
        eq(protocol.SCHEMA_VERSION, 11)
        eq(protocol.USER_AGENT_PREFIX, "anki")
        eq(protocol.CHUNK_SIZE, 250)
        eq(protocol.MAX_REDIRECTS, 3)

        -- cv: "anki,<version> (kindleanki),koreader" (ankiweb validates this).
        assert(protocol.CLIENT_VERSION:sub(1, 5) == "anki,", protocol.CLIENT_VERSION)
        local _, commas = protocol.CLIENT_VERSION:gsub(",", "")
        assert(commas >= 2, "cv needs at least two commas")
        assert(protocol.CLIENT_VERSION:find(protocol.VERSION, 1, true))
        assert(protocol.CLIENT_VERSION:find("kindleanki", 1, true))
        assert(protocol.client_version("9.9.9")
            == "anki,9.9.9 (kindleanki),koreader")

        -- c: short identity, no required shape beyond "has the key".
        eq(protocol.CLIENT_ID, protocol.VERSION .. ",kindleanki,koreader")
        eq(protocol.client_id("9.9.9"), "9.9.9,kindleanki,koreader")

        eq(#protocol.ROUTES, 12)
        eq(protocol.ROUTES[1], "hostKey")
        eq(protocol.ROUTES[12], "download")
    end,

    ["card_row is 18 columns in schema-18 order"] = function()
        local row = protocol.card_row(FULL_CARD)
        eq(#row, 18, "column count")
        eq(row[1], 1790701395009, "id")
        eq(row[2], 1790701395009, "nid")
        eq(row[3], 1, "did")
        eq(row[4], 2, "ord")
        eq(row[5], 1790701395, "mod")
        eq(row[6], -1, "usn")
        eq(row[7], 0, "type")
        eq(row[8], 0, "queue")
        eq(row[9], 1, "due")
        eq(row[14], 0, "left")
        eq(row[18], "{}", "data")
        -- Positional arrays must not carry string keys.
        assert(next(row, 18) == nil, "card_row must be a pure array")
    end,

    ["note_row is 11 columns and pins sfld/csum to empty strings"] = function()
        local row = protocol.note_row(FULL_NOTE)
        eq(#row, 11, "column count")
        eq(row[1], 1790701395009, "id")
        eq(row[2], "A+prSh9/iM", "guid")
        eq(row[3], 1790701394569, "mid")
        eq(row[5], -1, "usn")
        eq(row[6], " x ", "tags")
        eq(row[7], "nfront\31nback", "flds")
        -- rslib hardcodes these, and the DB columns are integers: sending them
        -- makes the whole chunk fail with "invalid type: integer, expected a
        -- string".
        eq(row[8], "", "sfld must be the empty string on the wire")
        eq(row[9], "", "csum must be the empty string on the wire")
        eq(row[10], 0, "flags")
        eq(row[11], "", "data")
    end,

    ["revlog_row is 9 columns in order"] = function()
        local row = protocol.revlog_row(FULL_REVLOG)
        eq(#row, 9, "column count")
        eq(row[1], 1790701395100, "id")
        eq(row[2], 1790701395009, "cid")
        eq(row[3], -1, "usn")
        eq(row[4], 3, "ease")
        eq(row[5], 10, "ivl")
        eq(row[6], 1, "lastIvl")
        eq(row[7], 2500, "factor")
        eq(row[8], 12345, "time")
        eq(row[9], 1, "type")
    end,

    ["row builders fill missing fields with wire-safe defaults"] = function()
        local card = protocol.card_row({ id = 5 })
        eq(#card, 18)
        eq(card[1], 5)
        eq(card[3], 0, "missing integer defaults to 0")
        eq(card[18], "", "missing text default to empty string")
        local note = protocol.note_row({ id = 7, guid = "g" })
        eq(note[2], "g")
        eq(note[6], "", "missing tags string")
        eq(note[7], "", "missing flds string")
        local revlog = protocol.revlog_row({})
        eq(revlog[7], 0)
    end,

    ["usn_override rewrites the value a peer must never see as -1"] = function()
        -- Optional extra: the caller may rewrite pending rows in one pass.
        eq(protocol.card_row(FULL_CARD, 42)[6], 42)
        eq(protocol.note_row(FULL_NOTE, 42)[5], 42)
        eq(protocol.revlog_row(FULL_REVLOG, 42)[3], 42)
        -- Without the override the stored value is forwarded unchanged.
        eq(protocol.card_row(FULL_CARD)[6], -1)
    end,

    ["row_to_card round-trips and tolerates short/null rows"] = function()
        local table_card = protocol.row_to_card(protocol.card_row(FULL_CARD))
        for field, expected in pairs(FULL_CARD) do
            eq(table_card[field], expected, "card." .. field)
        end

        -- A short row: serde's default means trailing fields may be absent.
        local short = protocol.row_to_card({ 1, 2, 3 })
        eq(short.id, 1)
        eq(short.nid, 2)
        eq(short.did, 3)
        eq(short.ord, 0)
        eq(short.data, "", "text columns default to empty string")

        -- A JSON null (nil or the explicit sentinel) behaves like "absent".
        local with_null = protocol.row_to_card({
            [1] = 9,
            [3] = nil,
            [18] = json.null,
        })
        eq(with_null.id, 9)
        eq(with_null.did, 0)
        eq(with_null.data, "")

        assert(protocol.row_to_card(nil) == nil, "non-table input is tolerated")
    end,

    ["row_to_note round-trips and normalizes sfld/csum"] = function()
        local note = protocol.row_to_note(protocol.note_row(FULL_NOTE))
        eq(note.id, FULL_NOTE.id)
        eq(note.guid, FULL_NOTE.guid)
        eq(note.mid, FULL_NOTE.mid)
        eq(note.usn, -1)
        eq(note.tags, FULL_NOTE.tags)
        eq(note.flds, FULL_NOTE.flds)
        eq(note.sfld, "")
        eq(note.csum, "")
        eq(note.flags, 0)
        eq(note.data, "")

        -- null / missing entries and numeric legacy values are tolerated.
        local tolerant = protocol.row_to_note({
            [1] = 3,
            [8] = 123,
            [9] = nil,
        })
        eq(tolerant.sfld, "123")
        eq(tolerant.csum, "")
        eq(tolerant.guid, "")
        assert(protocol.row_to_note(nil) == nil)
    end,

    ["row_to_revlog round-trips"] = function()
        local revlog = protocol.row_to_revlog(protocol.revlog_row(FULL_REVLOG))
        for field, expected in pairs(FULL_REVLOG) do
            eq(revlog[field], expected, "revlog." .. field)
        end
        local short = protocol.row_to_revlog({ 1, 2 })
        eq(short.id, 1)
        eq(short.cid, 2)
        eq(short.type, 0)
        assert(protocol.row_to_revlog(nil) == nil)
    end,

    ["rows survive a JSON encode/decode round trip"] = function()
        local card = protocol.row_to_card(
            json.decode(json.encode(protocol.card_row(FULL_CARD))))
        eq(card.id, FULL_CARD.id)
        eq(card.data, FULL_CARD.data)

        local note = protocol.row_to_note(
            json.decode(json.encode(protocol.note_row(FULL_NOTE))))
        eq(note.flds, FULL_NOTE.flds)

        local revlog = protocol.row_to_revlog(
            json.decode(json.encode(protocol.revlog_row(FULL_REVLOG))))
        eq(revlog.time, FULL_REVLOG.time)
    end,

    ["sanity_counts builds the positional client field"] = function()
        local counts = protocol.sanity_counts(3, 4, 5, 6)
        eq(#counts, 8, "eight top-level counts")
        eq(#counts[1], 3, "due counts are a 3-tuple")
        eq(counts[1][1], 0)
        eq(counts[2], 3, "cards")
        eq(counts[3], 4, "notes")
        eq(counts[4], 5, "revlog")
        eq(counts[5], 6, "graves")
        eq(counts[6], 0, "notetypes default")
        eq(counts[7], 0, "decks default")
        eq(counts[8], 0, "deck_config default")
        eq(encode(counts), "[[0,0,0],3,4,5,6,0,0,0]")

        -- Optional fifth argument: the schema-object counts the server also
        -- compares. Without them a real sync would report "bad".
        local full = protocol.sanity_counts(3, 4, 5, 6, {
            notetypes = 7,
            decks = 8,
            deck_config = 9,
        })
        eq(encode(full), "[[0,0,0],3,4,5,6,7,8,9]")
        eq(protocol.body_sanity_check2(full),
            '{"client":[[0,0,0],3,4,5,6,7,8,9]}')
    end,

    ["request bodies have the shapes rslib deserializes"] = function()
        local header = json.decode(protocol.header_json("abc", "sess01"))
        eq(header.v, 11)
        eq(header.k, "abc")
        eq(header.c, protocol.CLIENT_ID)
        eq(header.s, "sess01")
        eq(protocol.header_json("", "sess01"):find('"k":""', 1, true) ~= nil,
            true)

        local meta = json.decode(protocol.body_meta())
        eq(meta.v, 11)
        eq(meta.cv, protocol.CLIENT_VERSION)

        local host_key = json.decode(protocol.body_host_key("a@b.c", "pw"))
        eq(host_key.u, "a@b.c")
        eq(host_key.p, "pw")

        local start = json.decode(protocol.body_start(7, true))
        eq(start.minUsn, 7)
        eq(start.lnewer, true)
        eq(start.graves, nil, "deprecated graves field is omitted")

        local empty_changes = json.decode(protocol.body_apply_changes())
        eq(encode(empty_changes.changes.decks), "[[],[]]")
        eq(encode(empty_changes.changes.models), "[]")
        eq(encode(empty_changes.changes.tags), "[]")

        -- A decoded changes table keeps its array marks through re-encoding.
        local decoded = json.decode(
            '{"models":[],"decks":[[],[]],"tags":[],"conf":{"curDeck":1},"crt":1}')
        local round_trip = json.decode(protocol.body_apply_changes(decoded))
        eq(encode(round_trip.changes.decks), "[[],[]]")
        eq(round_trip.changes.conf.curDeck, 1)

        eq(protocol.body_empty(), "{}")
        eq(protocol.body_sanity_check2(protocol.sanity_counts(1, 2, 3, 4)),
            '{"client":[[0,0,0],1,2,3,4,0,0,0]}')
    end,

    ["body_apply_chunk omits empty lists and keeps rows positional"] = function()
        local card = protocol.card_row(FULL_CARD)
        local note = protocol.note_row(FULL_NOTE)
        local body = json.decode(protocol.body_apply_chunk({
            done = true,
            cards = { card },
            notes = { note },
            revlog = {},
        }))
        eq(body.chunk.done, true)
        eq(#body.chunk.cards, 1)
        eq(#body.chunk.cards[1], 18)
        eq(#body.chunk.notes[1], 11)
        eq(body.chunk.revlog, nil, "empty arrays are omitted, not sent as []")

        local done_only = json.decode(protocol.body_apply_chunk({ done = true }))
        eq(encode(done_only), '{"chunk":{"done":true}}')

        local finished = json.decode(protocol.body_apply_chunk({ done = false }))
        eq(finished.chunk.done, false, "done must be a JSON boolean")
    end,
}
