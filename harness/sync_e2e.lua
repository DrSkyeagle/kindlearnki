--[[--
End-to-end sync against harness/mock_ankiweb.py over a real socket.

Unlike tests/test_runner.lua (which drives a fake client), this uses the real
Client + Transport: zstd framing, the anki-sync header, HTTP POST, and the
JSON bodies the plugin actually puts on the wire.  It is the closest thing to
a real AnkiWeb sync that can run without credentials.

    COLLECTION=<collection.anki2> MOCK_PORT=9123 MOCK_LOG=/tmp/mock.jsonl \
      ./luajit /mnt/d/ankindle/harness/sync_e2e.lua

The mock runs in `normal` or `structural` mode (see mock_ankiweb.py).  In
structural mode the first applyChanges carries a deck change, which must make
the runner adopt the server collection and still deliver the pending review.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"
local collection_path = assert(os.getenv("COLLECTION"), "COLLECTION is required")
local port = tonumber(os.getenv("MOCK_PORT")) or 9123
local log_path = os.getenv("MOCK_LOG") or "/tmp/mock-sync.jsonl"
local mode = os.getenv("MOCK_MODE") or "normal"

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

package.path = plugin_dir .. "/?.lua;" .. package.path

local json = require("sync.json")
local Client = require("sync.client")
local Transport = require("sync.transport")
local Runner = require("sync.runner")
local Collection = require("model.collection")

local function copy(path)
    local target = "/tmp/e2e-" .. tostring(os.time()) .. "-"
        .. tostring(math.random(100000)) .. ".anki2"
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do
        local input = io.open(path .. suffix, "rb")
        if input then
            local data = input:read("*a")
            input:close()
            local output = assert(io.open(target .. suffix, "wb"))
            output:write(data)
            output:close()
        end
    end
    return target
end

local function cleanup(path)
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do
        os.remove(path .. suffix)
    end
end

--- Every applyChunk body the mock recorded, decoded.
local function pushed_chunks()
    local chunks = {}
    local handle = io.open(log_path, "rb")
    if not handle then
        return chunks
    end
    for line in handle:lines() do
        local ok, entry = pcall(json.decode, line)
        if ok and type(entry) == "table" and tostring(entry.path) == "applyChunk.pg" then
            chunks[#chunks + 1] = entry.body
        end
    end
    handle:close()
    return chunks
end

local function saw(path)
    local handle = io.open(log_path, "rb")
    if not handle then
        return false
    end
    for line in handle:lines() do
        local ok, entry = pcall(json.decode, line)
        if ok and type(entry) == "table" and tostring(entry.path) == path then
            handle:close()
            return true
        end
    end
    handle:close()
    return false
end

local path = copy(collection_path)
local collection = Collection.open(path)
local failures = 0

local function check(ok, message)
    if ok then
        print("E2E-OK " .. message)
    else
        failures = failures + 1
        print("E2E-FAIL " .. message)
    end
end

local ok_all, err = pcall(function()
    collection:load_decks()
    local deck_ids = collection:deck_subtree_ids(collection:active_deck_id())
    local card = collection:cards_in_decks(deck_ids)[1]
    assert(card, "fixture has no cards in the active deck")
    local now = os.time()
    -- Simulate one review: the card and a revlog row become pending, mod moves.
    collection.conn:run(
        "update cards set usn = -1, mod = ?, reps = reps + 1, due = ? where id = ?",
        now, card.due + 1, card.id)
    collection.conn:run([[insert or ignore into revlog
        (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
        values (?, ?, -1, 3, 1, 0, 2500, 1000, 1)]], now * 1000, card.id)
    collection.conn:run("update col set mod = ?", now * 1000)

    local client = Client.new{
        endpoint = string.format("http://127.0.0.1:%d/", port),
        hkey = "e2e-test-key",
        client_version = "0.2.19-e2e",
        transport = Transport,
    }
    local base = "/tmp/e2e-root-" .. tostring(os.time())
    local Paths = require("core.paths")
    local paths = Paths.new(base, base .. "/settings")
    assert(Paths.ensure(paths))
    local runner = Runner.new{
        collection = collection,
        client = client,
        paths = paths,
    }
    local result = runner:sync()
    print("E2E-RESULT status=" .. tostring(result.status)
        .. " message=" .. tostring(result.message))
    check(result.status == "normal", "sync finished normally")

    if mode == "structural" then
        check(saw("download"), "structure change made the client adopt the server copy")
    end

    local chunks = pushed_chunks()
    local found_card, found_revlog = false, false
    for _, body in ipairs(chunks) do
        local chunk = body and body.chunk or {}
        for _, row in ipairs(chunk.cards or {}) do
            if tonumber(row[1]) == tonumber(card.id) then
                found_card = true
                if tonumber(row[6]) == -1 then
                    check(false, "pushed card still has usn = -1")
                end
            end
        end
        for _, row in ipairs(chunk.revlog or {}) do
            if tonumber(row[2]) == tonumber(card.id) then
                found_revlog = true
            end
        end
    end
    check(found_card, "the reviewed card reached the server")
    check(found_revlog, "the revlog entry reached the server")
    check(#chunks > 0, "applyChunk was called at least once")

    -- A second sync must be a no-op against the mock's new modified time.
    local second = runner:sync()
    print("E2E-SECOND status=" .. tostring(second.status))
    check(second.status == "noChanges" or second.status == "normal",
        "second sync settled instead of demanding a full sync")
end)

collection:close()
cleanup(path)
if not ok_all then
    print("E2E-ERROR " .. tostring(err))
    failures = failures + 1
end
print(failures == 0 and "E2E-PASS" or ("E2E-FAILURES " .. failures))
os.exit(failures == 0 and 0 or 1)
