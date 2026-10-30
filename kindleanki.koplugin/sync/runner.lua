-- Incremental and whole-collection sync orchestration.
--
-- This module is the only place that knows the order of the v11 conversation:
--
--   meta -> [existing changes?] -> start -> applyChanges -> pull chunks ->
--   push chunks -> sanityCheck2 -> finish
--
-- Transport lives in sync/client.lua and merge rules in sync/store.lua, so the
-- sequence can be unit tested with a fake client (tests/test_runner.lua).

local Store = require("sync.store")
local protocol = require("sync.protocol")
local Log = require("core.log")

local Runner = {}
local MT = { __index = Runner }

-- Sync decisions are invisible in the UI ("成功" and "其实什么都没发出去"
-- look the same), and crash.log is the only channel on the device.  One line
-- per decision, no card data.
local function note(fmt, ...)
    pcall(Log.info, string.format("sync: " .. fmt, ...))
end

local function translate_error(err)
    if err == nil then
        return "未知错误"
    end
    local text = tostring(err)
    if text:find("hkey", 1, true) or text:find("401", 1, true)
        or text:find("403", 1, true) then
        return "登录已失效，请重新登录"
    elseif text:find("timeout", 1, true) or text:find("超时", 1, true) then
        return "网络超时，请检查 Wi-Fi 后重试"
    elseif text:find("connect", 1, true) or text:find("网络", 1, true) then
        return "网络不可用，请检查 Wi-Fi"
    end
    return text
end

--- @tparam table opts { collection, client, paths, progress }
-- `collection` is optional for the very first full download: there is nothing
-- to open yet, and `paths` is enough to place the downloaded file.
function Runner.new(opts)
    assert(opts, "opts are required")
    assert(opts.collection or opts.paths, "collection or paths are required")
    assert(opts.client, "client is required")
    if opts.collection then
        assert(opts.paths or opts.collection.path, "paths are required")
    end
    return setmetatable({
        collection = opts.collection,
        client = opts.client,
        paths = opts.paths,
        progress = opts.progress or function() end,
    }, MT)
end

function Runner:log(stage, detail)
    pcall(self.progress, stage, detail)
end

function Runner:login(email, password)
    local hkey, err = self.client:host_key(email, password)
    if not hkey then
        return nil, translate_error(err)
    end
    return hkey
end

--==========================================================================
-- Incremental
--==========================================================================

--- Pull every pending server chunk into the local collection.
function Runner:pull(meta)
    local pulled = 0
    while true do
        local chunk, err = self.client:chunk()
        if not chunk then
            return nil, translate_error(err)
        end
        if #(chunk.cards or {}) > 0 or #(chunk.notes or {}) > 0
            or #(chunk.revlog or {}) > 0 then
            Store.apply_chunk(self.collection, chunk)
            pulled = pulled + 1
        end
        self:log("pull", pulled)
        if chunk.done or (chunk.done == nil and pulled > 10000) then
            break
        end
    end
    note("pull chunks=%d", pulled)
    return true
end

--- Push all locally pending rows in batches.
function Runner:push(meta)
    local pending = Store.pending(self.collection)
    note("push pending cards=%d notes=%d revlog=%d graves=%d",
        #pending.cards, #pending.notes, #pending.revlog, #pending.graves)
    Store.mark_usns(self.collection, meta.usn)
    local chunks = Store.chunks(pending, meta.usn, 1000)
    for index, chunk in ipairs(chunks) do
        local ok, err = self.client:apply_chunk(chunk)
        if not ok then
            Store.restore_pending(self.collection, pending)
            return nil, translate_error(err)
        end
        note("push chunk=%d cards=%d notes=%d revlog=%d done=%s", index,
            #(chunk.cards or {}), #(chunk.notes or {}), #(chunk.revlog or {}),
            tostring(chunk.done))
        self:log("push", index)
    end
    return true
end

--- Adopt the server's collection while keeping the local reviews.
--
-- Anki requires a WHOLE-collection transfer when the two sides disagree on
-- schema (scm) or when applyChanges carries structural changes (deck/notetype/
-- tag edits).  Doing that blindly destroys whatever was reviewed offline, and
-- a full *upload* raises scm again, which forces the other device to full-sync
-- in turn -- the ping-pong this replaces.
--
-- So: snapshot the pending rows, take the server's file, replay the snapshot
-- on top (mtime rules decide the winner, same as a normal chunk merge), mark
-- the collection modified so a normal sync follows, and let the caller rerun
-- the handshake against the new state.
--
-- @treturn boolean|nil true on success
-- @treturn string|nil error message
function Runner:adopt_server_collection(reason)
    if not self.collection then
        -- Nothing local to lose (first sync): a plain download is enough.
        local downloaded, err = self:full_download()
        return downloaded, err
    end
    if self.adopted then
        -- Second structural change in one run: the other device is actively
        -- editing while we sync, or the download did not change scm.  Do not
        -- loop; ask the user.
        return nil, "结构在一次同步里变了两次（" .. tostring(reason) .. "），请重试"
    end
    self.adopted = true

    local pending = Store.pending(self.collection)
    note("adopt server collection (%s): pending cards=%d notes=%d revlog=%d",
        tostring(reason), #pending.cards, #pending.notes, #pending.revlog)

    -- Close the half-finished incremental session; the download below starts a
    -- fresh one.
    pcall(function()
        self.client:abort()
    end)

    local downloaded, err = self:full_download()
    if not downloaded then
        return nil, err
    end

    if #pending.cards + #pending.notes + #pending.revlog > 0 then
        -- pending rows are named tables (what the encoder wants); apply_chunk
        -- takes wire arrays, so encode them back with usn = -1.
        local function to_wire(rows, encode)
            local wire = {}
            for _, row in ipairs(rows) do
                wire[#wire + 1] = encode(row, -1)
            end
            return wire
        end
        Store.apply_chunk(self.collection, {
            done = true,
            cards = to_wire(pending.cards, protocol.card_row),
            notes = to_wire(pending.notes, protocol.note_row),
            revlog = to_wire(pending.revlog, protocol.revlog_row),
        })
        Store.mark_local_modified(self.collection)
        note("replayed cards=%d notes=%d revlog=%d",
            #pending.cards, #pending.notes, #pending.revlog)
    end
    return true
end

--- Run one incremental sync.
-- @treturn table { status = "noChanges"|"normal"|"error", message }
function Runner:sync()
    self:log("meta")
    if self.collection then
        -- Pick up col.mod/usn written by reviews since the file was opened.
        Store.refresh_timestamps(self.collection)
    end
    local meta, err = self.client:meta()
    if not meta then
        return { status = "error", message = translate_error(err) }
    end

    local needs_full, reason = Store.requires_full_sync(self.collection, meta)
    if needs_full then
        note("schema mismatch local=%s server=%s", tostring(self.collection.schema_modified),
            tostring(meta.scm))
        local adopted, adopt_error = self:adopt_server_collection(reason)
        if not adopted then
            return { status = "error", message = tostring(adopt_error or reason) }
        end
        return self:sync()
    end

    if meta.mod == self.collection.modified and meta.mod ~= 0 then
        note("no changes local_mod=%s server_mod=%s usn=%s/%s",
            tostring(self.collection.modified), tostring(meta.mod),
            tostring(self.collection.usn), tostring(meta.usn))
        return { status = "noChanges", message = "已是最新" }
    end
    note("sync local_mod=%s server_mod=%s usn=%s/%s", tostring(self.collection.modified),
        tostring(meta.mod), tostring(self.collection.usn), tostring(meta.usn))

    self:log("start")
    -- `lnewer` tells the server whether our copy is the newer one; it only
    -- decides who sends the legacy `config` blob, but sending it wrong is a
    -- protocol lie the server can act on.
    local local_is_newer = (tonumber(self.collection.modified) or 0)
        > (tonumber(meta.mod) or 0)
    local graves, start_error = self.client:start(self.collection.usn, local_is_newer)
    if graves == nil then
        return { status = "error", message = translate_error(start_error) }
    end
    if graves then
        for _, oid in ipairs(graves.cards or {}) do
            Store.apply_graves(self.collection, { { oid = oid, type = 0 } })
        end
        for _, oid in ipairs(graves.notes or {}) do
            Store.apply_graves(self.collection, { { oid = oid, type = 1 } })
        end
        for _, oid in ipairs(graves.decks or {}) do
            Store.apply_graves(self.collection, { { oid = oid, type = 2 } })
        end
    end

    self:log("applyChanges")
    local changes, changes_error = self.client:apply_changes({
        models = {},
        decks = { {}, {} },
        tags = {},
    })
    if not changes then
        return { status = "error", message = translate_error(changes_error) }
    end
    local structural = (#(changes.models or {}) > 0)
        or (#(changes.decks[1] or {}) > 0) or (#(changes.decks[2] or {}) > 0)
        or (#(changes.tags or {}) > 0)
    if structural then
        local counts = string.format("models=%d decks=%d/%d tags=%d",
            #(changes.models or {}), #(changes.decks[1] or {}),
            #(changes.decks[2] or {}), #(changes.tags or {}))
        note("applyChanges structural %s", counts)
        -- Structural edits cannot be merged with the card/note tables we know
        -- how to write, so take the server's collection and replay the local
        -- reviews instead of making the user choose a side.
        local adopted, adopt_error = self:adopt_server_collection(counts)
        if not adopted then
            return { status = "error", message = tostring(adopt_error or "结构同步失败") }
        end
        return self:sync()
    end

    local pulled, pull_error = self:pull(meta)
    if not pulled then
        return { status = "error", message = pull_error }
    end

    local pushed, push_error = self:push(meta)
    if not pushed then
        return { status = "error", message = push_error }
    end

    self:log("sanityCheck2")
    local counts = Store.sanity_counts(self.collection)
    local payload = protocol.sanity_counts(counts.cards, counts.notes,
        counts.revlog, counts.graves, counts)
    local status, sanity_error = self.client:sanity_check2(payload)
    if not status then
        return { status = "error", message = translate_error(sanity_error) }
    end
    if status ~= "ok" then
        note("sanity mismatch, taking the server copy")
        local adopted, adopt_error = self:adopt_server_collection("sanity")
        if not adopted then
            return { status = "error", message = tostring(adopt_error or "数据校验不一致") }
        end
        return self:sync()
    end

    self:log("finish")
    local new_mod, finish_error = self.client:finish()
    if not new_mod then
        return { status = "error", message = translate_error(finish_error) }
    end
    Store.after_finish(self.collection, new_mod, meta.usn)
    note("finished server_mod=%s local_usn_now=%s", tostring(new_mod),
        tostring(self.collection.usn))
    return { status = "normal", message = "同步完成", new_mod = new_mod }
end

--==========================================================================
-- Whole collection
--==========================================================================

--- Download the server's collection and install it atomically.
function Runner:full_download()
    local paths = self.paths
    assert(paths, "paths are required for a full download")

    local raw = paths.root .. "/collection.incoming"
    -- A first sync has no local collection to open (an empty SQLite file has no
    -- `col` row, so opening one first would fail before the download starts).
    local target = self.collection and self.collection.path or paths.collection
    local backup = target .. ".bak"

    self:log("download")
    -- sync/client.lua owns the zstd framing: `download()` returns the raw
    -- sqlite bytes already, so writing them straight to disk is the whole
    -- decompression step.
    local body, err = self.client:download()
    if not body then
        return nil, translate_error(err)
    end

    local file, open_error = io.open(raw, "wb")
    if not file then
        return nil, "无法写入临时文件：" .. tostring(open_error)
    end
    file:write(body)
    file:close()

    local verification = self:verify_collection(raw)
    if not verification then
        os.remove(raw)
        return nil, "下载的库校验失败"
    end

    -- Keep the old file until the new one is in place; the reverse order would
    -- lose both if the rename failed.  The handle must be closed first: on
    -- Windows a rename over an open SQLite file fails, and on any OS the old
    -- handle would keep pointing at the replaced inode.
    if self.collection then
        pcall(self.collection.close, self.collection)
    end
    os.remove(backup)
    -- The existence probe must be closed before the rename: on Windows an open
    -- handle makes os.rename fail, and the whole download then reports
    -- "无法备份旧库" even though nothing is wrong.
    local probe = io.open(target, "rb")
    local target_exists = probe ~= nil
    if probe then
        probe:close()
    end
    if target_exists then
        local renamed = os.rename(target, backup)
        if not renamed then
            os.remove(raw)
            return nil, "无法备份旧库"
        end
    end
    local installed = os.rename(raw, target)
    if not installed then
        os.rename(backup, target)
        os.remove(raw)
        return nil, "无法写入新库"
    end
    -- A WAL left over from the old file must never be replayed against the new
    -- one: SQLite would apply the previous journal to a different database.
    -- Closing the collection above normally removes these, but a crash or a
    -- killed process can leave them behind.
    for _, suffix in ipairs({ "-wal", "-shm" }) do
        os.remove(target .. suffix)
    end
    if self.collection then
        self.collection:reload()
    end
    return true
end

function Runner:verify_collection(path)
    local ok, Conn = pcall(require, "db.conn")
    if not ok then
        return nil, "db layer unavailable"
    end
    local conn = Conn.open(path, true)
    -- The collection's indexes use `COLLATE unicase`; without registering it,
    -- even `pragma quick_check` fails with "no such collation sequence" and a
    -- perfectly good download would be rejected.
    pcall(function()
        require("db.collation").install(conn)
    end)
    local verified, err = pcall(function()
        local row = conn:first("pragma quick_check")
        assert(row and row[1] == "ok", "quick_check failed")
        local version = conn:first("select ver from col")
        assert(version and tonumber(version[1]) == 18, "schema version is not 18")
    end)
    conn:close()
    if not verified then
        return nil, err
    end
    return true
end

--- Upload the local collection (after before_upload bookkeeping).
function Runner:full_upload()
    local zstd = require("sync.zstd")
    local paths = self.paths
    assert(paths, "paths are required for a full upload")

    Store.before_upload(self.collection)

    local compressed = paths.root .. "/collection.outgoing.zst"
    self:log("upload")
    local ok, err = zstd.compress_file(self.collection.path, compressed, 1024 * 1024)
    if not ok then
        os.remove(compressed)
        return nil, "压缩失败：" .. tostring(err)
    end

    local file = io.open(compressed, "rb")
    if not file then
        return nil, "无法读取压缩结果"
    end
    local body = file:read("*a")
    file:close()
    os.remove(compressed)

    -- Compressed here (streaming, so the raw 5.5 MB file never sits in memory
    -- next to its frame); client.upload() recognises the zstd magic and sends
    -- the frame as-is instead of compressing it twice.
    local uploaded, upload_error = self.client:upload(body)
    if not uploaded then
        return nil, translate_error(upload_error)
    end
    return true
end

return Runner
