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

local Runner = {}
local MT = { __index = Runner }

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
function Runner.new(opts)
    assert(opts and opts.collection, "collection is required")
    assert(opts.client, "client is required")
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
    return true
end

--- Push all locally pending rows in batches.
function Runner:push(meta)
    local pending = Store.pending(self.collection)
    Store.mark_usns(self.collection, meta.usn)
    local chunks = Store.chunks(pending, meta.usn, 1000)
    for index, chunk in ipairs(chunks) do
        local ok, err = self.client:apply_chunk(chunk)
        if not ok then
            return nil, translate_error(err)
        end
        self:log("push", index)
    end
    return true
end

--- Run one incremental sync.
-- @treturn table { status = "noChanges"|"normal"|"fullRequired", message }
function Runner:sync()
    self:log("meta")
    local meta, err = self.client:meta()
    if not meta then
        return { status = "error", message = translate_error(err) }
    end

    local needs_full, reason = Store.requires_full_sync(self.collection, meta)
    if needs_full then
        return { status = "fullRequired", message = reason }
    end

    if meta.mod == self.collection.modified and meta.mod ~= 0 then
        return { status = "noChanges", message = "已是最新" }
    end

    self:log("start")
    local graves, start_error = self.client:start(self.collection.usn, false)
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
        return {
            status = "fullRequired",
            message = "桌面端改了笔记类型/牌组结构，需要整库同步",
        }
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
        return { status = "fullRequired", message = "数据校验不一致" }
    end

    self:log("finish")
    local new_mod, finish_error = self.client:finish()
    if not new_mod then
        return { status = "error", message = translate_error(finish_error) }
    end
    Store.after_finish(self.collection, new_mod, meta.usn)
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
    local target = self.collection.path
    local backup = target .. ".bak"

    self:log("download")
    -- sync/client.lua owns the zstd framing: `download()` returns the raw
    -- sqlite bytes already, so writing them straight to disk is the whole
    -- decompression step.
    local body, err = self.client:download()
    if not body then
        return nil, translate_error(err)
    end

    local file = assert(io.open(raw, "wb"))
    file:write(body)
    file:close()

    local verification = self:verify_collection(raw)
    if not verification then
        os.remove(raw)
        return nil, "下载的库校验失败"
    end

    -- Keep the old file until the new one is in place; the reverse order would
    -- lose both if the rename failed.
    os.remove(backup)
    if io.open(target, "rb") then
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
    self.collection:reload()
    return true
end

function Runner:verify_collection(path)
    local ok, Conn = pcall(require, "db.conn")
    if not ok then
        return nil, "db layer unavailable"
    end
    local conn = Conn.open(path, true)
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
