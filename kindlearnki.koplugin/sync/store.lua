-- Database side of sync: what is pending, how inbound rows merge, what the
-- sanity check counts.
--
-- Rules (doc/SYNC-SPEC.md §3, from rslib/src/sync/collection/{normal,chunks,
-- sanity}.rs and the measured notes):
--   * pending rows are the ones with usn = -1;
--   * before sending, they are rewritten to the server's current usn -- -1 must
--     never reach the wire;
--   * an inbound row is applied unless the local copy is still pending *and*
--     newer (local.mod > incoming.mod);
--   * revlog rows are insert-or-ignore (they are immutable);
--   * every table must be free of usn = -1 before sanityCheck2.

local protocol = require("sync.protocol")
local Conn = require("db.conn")

local Store = {}

local CARD_COLUMNS =
    "id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"
local NOTE_COLUMNS =
    "id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data"
local REVLOG_COLUMNS =
    "id, cid, usn, ease, ivl, lastIvl, factor, time, type"

--- Rows changed locally since the last sync.
--
-- Returned as *named* tables (the `protocol.card_row` shape).  Handing the raw
-- positional rows from `select` to the wire encoder is what made every pushed
-- review arrive as a row of zeros: the encoder reads `row.id`, `row.nid`, ...
-- and an array has none of those, so all fields silently fell back to their
-- defaults while applyChunk answered 200 -- "同步成功" with nothing uploaded.
function Store.pending(collection)
    local function collect(sql, decode)
        local rows = {}
        for _, row in ipairs(collection.conn:all(sql)) do
            rows[#rows + 1] = decode and decode(row) or row
        end
        return rows
    end
    return {
        cards = collect("select " .. CARD_COLUMNS .. " from cards where usn = -1",
            protocol.row_to_card),
        notes = collect("select " .. NOTE_COLUMNS .. " from notes where usn = -1",
            protocol.row_to_note),
        revlog = collect("select " .. REVLOG_COLUMNS .. " from revlog where usn = -1",
            protocol.row_to_revlog),
        graves = collect("select oid, type from graves where usn = -1"),
    }
end

--- Rewrite pending usn values to `usn` (the server's current usn).
function Store.mark_usns(collection, usn)
    collection.conn:transaction(function()
        collection.conn:run("update cards set usn = ? where usn = -1", usn)
        collection.conn:run("update notes set usn = ? where usn = -1", usn)
        collection.conn:run("update revlog set usn = ? where usn = -1", usn)
        collection.conn:run("update graves set usn = ? where usn = -1", usn)
    end)
end

--- Build the request bodies the server expects from a pending snapshot.
function Store.chunks(pending, usn, chunk_size)
    usn = usn or 0
    chunk_size = chunk_size or 1000
    local chunks = {}

    local function new_chunk()
        return { done = false, cards = {}, notes = {}, revlog = {} }
    end

    local chunk = new_chunk()
    local function flush()
        if #chunk.cards > 0 or #chunk.notes > 0 or #chunk.revlog > 0 then
            chunks[#chunks + 1] = chunk
            chunk = new_chunk()
        end
    end

    local function push_row(rows, row)
        rows[#rows + 1] = row
        if #rows >= chunk_size then
            flush()
        end
    end

    for _, row in ipairs(pending.cards or {}) do
        push_row(chunk.cards, protocol.card_row(row, usn))
    end
    for _, row in ipairs(pending.notes or {}) do
        push_row(chunk.notes, protocol.note_row(row, usn))
    end
    for _, row in ipairs(pending.revlog or {}) do
        push_row(chunk.revlog, protocol.revlog_row(row, usn))
    end
    flush()
    return chunks
end

--==========================================================================
-- Inbound
--==========================================================================

local function local_is_newer(collection, table_name, id, incoming_mod)
    local row = collection.conn:first(
        string.format("select usn, mod from %s where id = ?", table_name), id)
    if not row then
        return false
    end
    if tonumber(row[1]) ~= -1 then
        -- Not pending locally: the server's copy wins, exactly like rslib's
        -- `!existing.usn.is_pending_sync(pending_usn) || ...`.
        return false
    end
    -- Both sides edited it: keep the local one unless the incoming row is
    -- strictly newer (a tie keeps the local pending edit).
    return tonumber(row[2]) >= (incoming_mod or 0)
end

local function upsert_card(collection, card)
    -- `data` holds a protobuf blob; a plain Lua string is bound as TEXT and
    -- rslib then refuses to read the card (`Vec<u8>` from a text value).  The
    -- column has no declared type, so SQLite keeps whatever class we send.
    collection.conn:run([[
        insert or replace into cards
            (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor,
             reps, lapses, left, odue, odid, flags, data)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], card.id, card.nid, card.did, card.ord, card.mod, card.usn,
        card.type, card.queue, card.due, card.ivl, card.factor,
        card.reps, card.lapses, card.left, card.odue, card.odid,
        card.flags, Conn.blob(card.data or ""))
end

local function upsert_note(collection, note)
    -- `data` is a protobuf blob for the same reason as cards.data.
    collection.conn:run([[
        insert or replace into notes
            (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], note.id, note.guid, note.mid, note.mod, note.usn, note.tags,
        note.flds, note.sfld, note.csum, note.flags, Conn.blob(note.data or ""))
end

local function insert_revlog(collection, revlog)
    collection.conn:run([[
        insert or ignore into revlog
            (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], revlog.id, revlog.cid, revlog.usn, revlog.ease, revlog.ivl,
        revlog.lastIvl, revlog.factor, revlog.time, revlog.type)
end

--- Merge one inbound chunk (arrays straight from the wire, or named tables).
-- @treturn number applied, number skipped
function Store.apply_chunk(collection, chunk)
    local applied, skipped = 0, 0
    collection.conn:transaction(function()
        for _, row in ipairs(chunk.cards or {}) do
            local card = protocol.row_to_card(row)
            if local_is_newer(collection, "cards", card.id, card.mod) then
                skipped = skipped + 1
            else
                upsert_card(collection, card)
                applied = applied + 1
            end
        end
        for _, row in ipairs(chunk.notes or {}) do
            local note = protocol.row_to_note(row)
            if local_is_newer(collection, "notes", note.id, note.mod) then
                skipped = skipped + 1
            else
                upsert_note(collection, note)
                applied = applied + 1
            end
        end
        for _, row in ipairs(chunk.revlog or {}) do
            insert_revlog(collection, protocol.row_to_revlog(row))
            applied = applied + 1
        end
    end)
    return applied, skipped
end

--- Delete rows the server reported as deleted (graves: 0=card 1=note 2=deck).
function Store.apply_graves(collection, graves)
    collection.conn:transaction(function()
        for _, grave in ipairs(graves or {}) do
            local oid, kind = grave.oid or grave[1], grave.type or grave[2]
            if kind == 0 then
                collection.conn:run("delete from cards where id = ?", oid)
            elseif kind == 1 then
                collection.conn:run(
                    "delete from notes where id = ?", oid)
            elseif kind == 2 then
                collection.conn:run("delete from decks where id = ?", oid)
            end
        end
    end)
end

--==========================================================================
-- Sanity check
--==========================================================================

function Store.sanity_counts(collection)
    local function count(sql)
        local row = collection.conn:first(sql)
        return tonumber(row and row[1]) or 0
    end
    return {
        cards = count("select count(*) from cards"),
        notes = count("select count(*) from notes"),
        revlog = count("select count(*) from revlog"),
        graves = count("select count(*) from graves"),
        decks = count("select count(*) from decks"),
        deck_config = count("select count(*) from deck_config"),
        notetypes = count("select count(*) from notetypes"),
        tags = count("select count(*) from tags"),
    }
end

function Store.has_pending(collection)
    local pending = Store.pending(collection)
    return #pending.cards > 0 or #pending.notes > 0
        or #pending.revlog > 0 or #pending.graves > 0
end

--==========================================================================
-- Whole-collection operations
--==========================================================================

--- Prepare a collection for a full upload (Anki's `before_upload`).
function Store.before_upload(collection)
    -- The uploaded file is read by AnkiWeb/desktop Anki, whose rslib rejects
    -- TEXT in BLOB columns.  Heal anything an older writer stored wrongly
    -- before the file leaves this device.
    collection:repair_blob_storage()
    local now_ms = math.floor(os.time() * 1000)
    collection.conn:transaction(function()
        collection.conn:run("delete from graves")
        collection.conn:run("update cards set usn = 0 where usn = -1")
        collection.conn:run("update notes set usn = 0 where usn = -1")
        collection.conn:run("update revlog set usn = 0 where usn = -1")
        collection.conn:run("update decks set usn = 0 where usn != 0")
        collection.conn:run("update deck_config set usn = 0 where usn != 0")
        collection.conn:run("update notetypes set usn = 0 where usn != 0")
        collection.conn:run("update tags set usn = 0 where usn != 0")
        -- Deliberately raise scm so other devices are told to download, then
        -- record that as the last-sync stamp (rslib before_upload: scm = now,
        -- ls = scm, usn + 1).  Leaving ls behind makes the next sync compare
        -- against a stale stamp and ask for another full sync.
        collection.conn:run(
            "update col set usn = usn + 1, scm = ?, mod = ?", now_ms, now_ms)
        collection.conn:run("update col set ls = scm")
    end)
    -- The in-memory copy is stale now (scm/usn/mod/ls all moved); callers that
    -- keep using the object would immediately see a schema mismatch.
    collection.schema_modified = now_ms
    collection.modified = now_ms
    collection.usn = (tonumber(collection.usn) or 0) + 1
    collection.ls = now_ms
end

--- Apply the bookkeeping that follows a successful incremental sync.
function Store.after_finish(collection, new_mod, server_usn)
    collection.conn:transaction(function()
        collection.conn:run("update col set ls = ?, usn = ?, mod = ?",
            new_mod, (server_usn or 0) + 1, new_mod)
    end)
    collection.ls = new_mod
    collection.modified = new_mod
    collection.usn = (server_usn or 0) + 1
    -- A plain re-sync should also heal a collection an older writer left with
    -- TEXT-typed BLOB columns (see model/collection.lua repair_blob_storage).
    -- The sync itself has already succeeded, so a repair failure (e.g. a busy
    -- file) must not be reported as a sync failure.
    pcall(collection.repair_blob_storage, collection)
end

--- Put the rows back into the pending state after a failed push.
--
-- `mark_usns` rewrites usn before the request goes out (that is what the wire
-- needs), so a network failure in the middle of the batch would otherwise
-- leave the rows looking "already sent" and their reviews would never reach
-- the server -- the exact "kindle says 成功 but the phone never sees it" bug.
function Store.restore_pending(collection, pending)
    pending = pending or {}
    local function key_of(row)
        return row and (row.id or row[1])
    end
    collection.conn:transaction(function()
        for _, card in ipairs(pending.cards or {}) do
            collection.conn:run("update cards set usn = -1 where id = ?", key_of(card))
        end
        for _, note in ipairs(pending.notes or {}) do
            collection.conn:run("update notes set usn = -1 where id = ?", key_of(note))
        end
        for _, revlog in ipairs(pending.revlog or {}) do
            collection.conn:run("update revlog set usn = -1 where id = ?", key_of(revlog))
        end
        for _, grave in ipairs(pending.graves or {}) do
            collection.conn:run(
                "update graves set usn = -1 where oid = ? and type = ?",
                grave.oid or grave[1], grave.type or grave[2])
        end
    end)
end

--- Mark the collection as modified now, without touching the row tables.
--
-- Used after replaying locally pending rows onto a freshly downloaded
-- collection: the rows are pending (usn = -1) again, and `mod` must differ
-- from the server's or the next sync would answer "no changes" and never push.
function Store.mark_local_modified(collection)
    local now_ms = math.floor(os.time() * 1000)
    collection.conn:run("update col set mod = ?", now_ms)
    collection.modified = now_ms
    return now_ms
end

--- Re-read the col row into the in-memory object.
--
-- `mod` moves on every review (sched/answer writes it straight to SQL), while
-- the object keeps whatever it had when the file was opened.  Comparing a
-- stale `mod` with the server's is how a sync can decide there is nothing to
-- do and leave the reviews on the device.
function Store.refresh_timestamps(collection)
    local row = collection.conn:first("select mod, scm, usn, ls from col")
    if not row then
        return false
    end
    collection.modified = row[1]
    collection.schema_modified = row[2]
    collection.usn = row[3]
    collection.ls = row[4]
    return true
end

--- True when the two sides disagree on schema and only a full sync can help.
function Store.requires_full_sync(collection, meta)
    if collection.schema_modified ~= meta.scm then
        return true, "两边结构不一致"
    end
    return false
end

return Store
