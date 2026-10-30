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

local Store = {}

local CARD_COLUMNS =
    "id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"
local NOTE_COLUMNS =
    "id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data"
local REVLOG_COLUMNS =
    "id, cid, usn, ease, ivl, lastIvl, factor, time, type"

--- Rows changed locally since the last sync.
function Store.pending(collection)
    local pending = {
        cards = collection.conn:all(
            "select " .. CARD_COLUMNS .. " from cards where usn = -1"),
        notes = collection.conn:all(
            "select " .. NOTE_COLUMNS .. " from notes where usn = -1"),
        revlog = collection.conn:all(
            "select " .. REVLOG_COLUMNS .. " from revlog where usn = -1"),
        graves = collection.conn:all(
            "select oid, type from graves where usn = -1"),
    }
    return pending
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
        return false
    end
    return tonumber(row[2]) > (incoming_mod or 0)
end

local function upsert_card(collection, card)
    collection.conn:run([[
        insert or replace into cards
            (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor,
             reps, lapses, left, odue, odid, flags, data)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], card.id, card.nid, card.did, card.ord, card.mod, card.usn,
        card.type, card.queue, card.due, card.ivl, card.factor,
        card.reps, card.lapses, card.left, card.odue, card.odid,
        card.flags, card.data)
end

local function upsert_note(collection, note)
    collection.conn:run([[
        insert or replace into notes
            (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], note.id, note.guid, note.mid, note.mod, note.usn, note.tags,
        note.flds, note.sfld, note.csum, note.flags, note.data)
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
        -- Deliberately raise scm so other devices are told to download.
        collection.conn:run(
            "update col set usn = usn + 1, scm = ?, mod = ?", now_ms, now_ms)
    end)
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

--- True when the two sides disagree on schema and only a full sync can help.
function Store.requires_full_sync(collection, meta)
    if collection.schema_modified ~= meta.scm then
        return true, "两边结构不一致"
    end
    return false
end

return Store
