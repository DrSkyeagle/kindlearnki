--[[--
Everything the plugin knows about Anki sync protocol v11, and nothing else.

This module is deliberately transport-free: it turns Lua tables into the
positional row arrays and request bodies that rslib's serde structs expect, and
turns received arrays back into named tables. `sync/client.lua` owns the HTTP
details; `sync/normal.lua`/`sync/full.lua` (later milestones) own the sync
bookkeeping.

Where the constants come from (see doc/SYNC-SPEC.md §1 for the evidence trail):

  * paths are `sync/<SyncMethod>` -- `[源码] rslib/src/sync/collection/protocol.rs:35-48`;
  * the `anki-sync` header carries exactly four keys `v/k/c/s`, and `v` is 11
    -- `[源码] rslib/src/sync/request/header_and_stream.rs:118-129`;
  * `cv` must start with `anki,` and carry at least two commas, otherwise
    AnkiWeb answers a bare 400 -- `[实测]`;
  * row order is fixed by the `Serialize_tuple` derives in
    `rslib/src/sync/collection/chunks.rs:46-87` and
    `rslib/src/revlog/mod.rs` (schema 18);
  * `NoteEntry` hardcodes `sfld`/`csum` to `""` on the wire
    -- `rslib/src/sync/collection/chunks.rs:384-400`, so sending the integer
    DB columns gets the whole chunk rejected.

@module sync.protocol
]]

local json = require("sync.json")

local M = {}

--- Wire identity. Kept in sync with `core/version.lua` by hand: version.lua is
--- the release identity, this is what goes on the wire, and tests pin the
--- shape (`anki,<ver> (kindleanki),koreader`) rather than loose matching.
M.VERSION = "0.1.0-dev"

M.ENDPOINT_DEFAULT = "https://sync.ankiweb.net/"

--- The `v` field of the sync header and of the `meta` request. Anki calls
--- this the sync version; this project's docs call schema 18 the collection
--- format, so the name is spelled out here to avoid confusing the two.
M.SCHEMA_VERSION = 11

--- `cv` must begin with this, hence the exported prefix, not a bare string
--- buried in the client.
M.USER_AGENT_PREFIX = "anki"

M.CHUNK_SIZE = 250

--- AnkiWeb answers `sync/meta` with 308 + Location for the per-user host.
M.MAX_REDIRECTS = 3

--- `c` header: short identity, no spaces needed. AnkiWeb only requires the
--- key to exist (an empty value is accepted), but a real value makes sync
--- logs on the server side attributable.
M.CLIENT_ID = M.VERSION .. ",kindleanki,koreader"

--- `cv` body field: Anki's "name,version (build),platform" shape.
M.CLIENT_VERSION = M.USER_AGENT_PREFIX .. "," .. M.VERSION
    .. " (kindleanki),koreader"

--- Every endpoint is a POST under this prefix.
M.ROUTES = {
    "hostKey",
    "meta",
    "start",
    "applyGraves",
    "applyChanges",
    "chunk",
    "applyChunk",
    "sanityCheck2",
    "finish",
    "abort",
    "upload",
    "download",
}

--- Grave kinds, in the order rslib writes them.
M.GRAVE_CARD = 0
M.GRAVE_NOTE = 1
M.GRAVE_DECK = 2

--==========================================================================
-- Row column order (schema 18)
--==========================================================================

M.CARD_FIELDS = {
    "id", "nid", "did", "ord", "mod", "usn", "type", "queue", "due",
    "ivl", "factor", "reps", "lapses", "left", "odue", "odid", "flags",
    "data",
}

M.NOTE_FIELDS = {
    "id", "guid", "mid", "mod", "usn", "tags", "flds", "sfld", "csum",
    "flags", "data",
}

M.REVLOG_FIELDS = {
    "id", "cid", "usn", "ease", "ivl", "lastIvl", "factor", "time", "type",
}

-- Columns that are strings on the wire. Everything else is an integer; anki's
-- serde types are strict enough that an empty string in an integer slot (or
-- the reverse) rejects the whole chunk.
local TEXT_DEFAULTS = {
    card = { data = true },
    note = {
        guid = true, tags = true, flds = true, sfld = true, csum = true,
        data = true,
    },
    revlog = {},
}

local function default_for(kind, field)
    return TEXT_DEFAULTS[kind][field] and "" or 0
end

local function read_field(row, field, kind, usn_override)
    local value = row and row[field]
    if json.is_null(value) then
        value = nil
    end
    if value == nil then
        value = default_for(kind, field)
    end
    if field == "usn" and usn_override ~= nil then
        value = usn_override
    end
    return value
end

local function row_from_table(kind, fields, row, usn_override)
    local out = {}
    for index = 1, #fields do
        out[index] = read_field(row, fields[index], kind, usn_override)
    end
    return out
end

--- Convert a decoded card table into the 18-column wire array.
-- @tparam table card named card columns (`model/collection.lua` shape)
-- @tparam[opt] number usn_override rewrite `usn` (never send -1 to the server)
-- @treturn table positional array, 18 entries
function M.card_row(card, usn_override)
    return row_from_table("card", M.CARD_FIELDS, card, usn_override)
end

--- Convert a decoded note table into the 11-column wire array.
--
-- `sfld` and `csum` are *always* empty strings: rslib's `From<Note> for
-- NoteEntry` hardcodes them, and the DB columns are integers, so forwarding
-- them would send an integer where serde expects a string.
function M.note_row(note, usn_override)
    local row = row_from_table("note", M.NOTE_FIELDS, note, usn_override)
    row[8] = ""
    row[9] = ""
    return row
end

--- Convert a decoded revlog table into the 9-column wire array.
function M.revlog_row(revlog, usn_override)
    return row_from_table("revlog", M.REVLOG_FIELDS, revlog, usn_override)
end

--==========================================================================
-- Row decoding (server -> local)
--==========================================================================

local function value_at(kind, array, index, field)
    local value = array and array[index]
    if json.is_null(value) then
        value = nil
    end
    if value == nil then
        return default_for(kind, field)
    end
    return value
end

local function row_to_table(kind, fields, array)
    if type(array) ~= "table" then
        return nil
    end
    local out = {}
    for index = 1, #fields do
        out[fields[index]] = value_at(kind, array, index, fields[index])
    end
    return out
end

--- Decode an 18-column wire array into a named card table.
--
-- Tolerates a short array (serde's `default` lets the server omit trailing
-- fields) and explicit nulls; text columns fall back to "" and integers to 0.
function M.row_to_card(array)
    return row_to_table("card", M.CARD_FIELDS, array)
end

--- Decode an 11-column wire array into a named note table.
--
-- Tolerates nulls and short rows. `sfld`/`csum` arrive as strings; a numeric
-- value from an older peer is stringified so the DB write path never sees a
-- type the column cannot store.
function M.row_to_note(array)
    local note = row_to_table("note", M.NOTE_FIELDS, array)
    if note then
        note.sfld = tostring(note.sfld)
        note.csum = tostring(note.csum)
    end
    return note
end

--- Decode a 9-column wire array into a named revlog table.
function M.row_to_revlog(array)
    return row_to_table("revlog", M.REVLOG_FIELDS, array)
end

--==========================================================================
-- Request bodies
--==========================================================================

--- `cv` for a given plugin version.
function M.client_version(version)
    return M.USER_AGENT_PREFIX .. "," .. tostring(version or M.VERSION)
        .. " (kindleanki),koreader"
end

--- `c` header value for a given plugin version.
function M.client_id(version)
    return tostring(version or M.VERSION) .. ",kindleanki,koreader"
end

--- The `anki-sync` header value.
-- @tparam string hkey host key, empty string during `hostKey`
-- @tparam string session six-character session key
-- @tparam[opt] string version plugin version
function M.header_json(hkey, session, version)
    return json.encode({
        v = M.SCHEMA_VERSION,
        k = hkey or "",
        c = M.client_id(version),
        s = session or "",
    })
end

--- `/sync/hostKey` body.
function M.body_host_key(username, password)
    return json.encode({ u = username or "", p = password or "" })
end

--- `/sync/meta` body.
function M.body_meta(version)
    return json.encode({
        v = M.SCHEMA_VERSION,
        cv = M.client_version(version),
    })
end

--- `/sync/start` body. `graves` is deliberately omitted: it is the deprecated
--- pre-v11 field, and the server treats a missing value as "none".
function M.body_start(min_usn, local_is_newer)
    return json.encode({
        minUsn = min_usn or 0,
        lnewer = local_is_newer and true or false,
    })
end

--- `/sync/applyChanges` body.
--
-- The `decks` field is a 2-tuple on the wire and must always be present.
-- `changes` may be omitted for an empty sync, or be a decoded response table
-- (whose arrays are already marked as arrays by the decoder).
function M.body_apply_changes(changes)
    if changes == nil then
        changes = {}
    end
    local decks = type(changes.decks) == "table" and changes.decks or {}
    local function as_array(value)
        return json.array(type(value) == "table" and value or {})
    end
    local normalized = {
        models = as_array(changes.models),
        -- A 2-tuple: (decks added/updated, decks removed). Both slots must
        -- exist and be arrays even when empty.
        decks = json.array({
            as_array(decks[1]),
            as_array(decks[2]),
        }),
        tags = as_array(changes.tags),
    }
    -- Pre-schema-18 clients may still send these; pass them through rather
    -- than dropping a field the server might be looking at.
    if changes.conf ~= nil then
        normalized.conf = changes.conf
    end
    if changes.crt ~= nil then
        normalized.crt = changes.crt
    end
    return json.encode({ changes = normalized })
end

--- `/sync/chunk`, `/sync/finish`, `/sync/abort` and `/sync/download` body.
--- serde accepts a plain `{}` for EmptyInput (`_pad` is optional).
function M.body_empty()
    return "{}"
end

--- `/sync/applyChunk` body.
--
-- Empty row lists are omitted: rslib serializes them with
-- `skip_serializing_if = "Vec::is_empty"`, and `done` must be a boolean.
-- @tparam table chunk `{ done = bool, cards = {...}, notes = {...}, revlog = {...} }`
function M.body_apply_chunk(chunk)
    chunk = chunk or {}
    local body = { done = chunk.done and true or false }
    for _, key in ipairs({ "cards", "notes", "revlog" }) do
        local rows = chunk[key]
        if type(rows) == "table" and #rows > 0 then
            body[key] = json.array(rows)
        end
    end
    return json.encode({ chunk = body })
end

--- The positional `SanityCheckCounts` array:
--- `[[new, learn, review], cards, notes, revlog, graves, models, decks, deck_config]`.
--
-- The server zeroes the due counts and the grave count before comparing, so
-- `graves_count` is informational; the six table counts decide ok/bad.
--
-- The four required arguments cover the row tables. The optional fifth
-- argument carries the schema-object counts (`notetypes`/`decks`/`deck_config`)
-- that `sanityCheck2` also compares; omitting them sends 0, which only matches
-- a collection with no notetypes/decks configs.
-- @tparam number cards
-- @tparam number notes
-- @tparam number revlog
-- @tparam number graves_count
-- @tparam[opt] table structural `{ notetypes = n, decks = n, deck_config = n }`
function M.sanity_counts(cards, notes, revlog, graves_count, structural)
    structural = structural or {}
    local function count(value)
        return tonumber(value) or 0
    end
    return json.array({
        json.array({ 0, 0, 0 }),
        count(cards),
        count(notes),
        count(revlog),
        count(graves_count),
        count(structural.notetypes),
        count(structural.decks),
        count(structural.deck_config),
    })
end

--- `/sync/sanityCheck2` body.
-- @tparam table client positional counts array (from `sanity_counts`)
function M.body_sanity_check2(client)
    return json.encode({ client = json.array(client) })
end

return M
