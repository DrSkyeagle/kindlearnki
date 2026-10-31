-- Sync orchestration against a fake client.
--
-- The real network cannot run in the L1 suite, but the *conversation order* can
-- be tested exactly: meta -> start -> applyChanges -> chunks -> applyChunk ->
-- sanityCheck2 -> finish, plus the bookkeeping that follows.  A fake client is
-- also the cheapest way to exercise the "server says our structure is stale"
-- and "sanity says bad" branches, which are otherwise unreachable offline.

local Helpers = require("helpers")
local Collection = require("model.collection")
local Runner = require("sync.runner")
local Store = require("sync.store")
local Paths = require("core.paths")
local protocol = require("sync.protocol")

local FIXTURE = os.getenv("KINDLEARNKI_TEST_COLLECTION")
local NEW_DECK = tonumber(os.getenv("KINDLEARNKI_NEW_DECK") or "1782139166456")

local function copy_fixture()
    assert(FIXTURE, "KINDLEARNKI_TEST_COLLECTION is not set")
    local target = Helpers.root .. "/../out/runner-" .. tostring(os.time())
        .. "-" .. tostring(math.random(100000)) .. ".anki2"
    for _, extension in ipairs({ "", "-wal", "-shm" }) do
        local input = io.open(FIXTURE .. extension, "rb")
        if input then
            local data = input:read("*a")
            input:close()
            local output = assert(io.open(target .. extension, "wb"))
            output:write(data)
            output:close()
        end
    end
    return target
end

local function cleanup(path)
    for _, extension in ipairs({ "", "-wal", "-shm" }) do
        os.remove(path .. extension)
    end
end

--- @tparam table behaviour { meta=, graves=, changes=, chunks=, sanity=, finish=, error_at= }
-- `meta` and `sanity` may be functions, which is how a test models a server
-- that answers differently on the retry after a download.
local function fake_client(behaviour, calls)
    local client = {}
    local function record(name)
        calls[#calls + 1] = name
        if behaviour.error_at == name then
            return nil, "network down"
        end
        return true
    end
    local function resolve(value)
        if type(value) == "function" then
            return value()
        end
        return value
    end

    function client:meta()
        local ok, err = record("meta")
        if not ok then
            return nil, err
        end
        return resolve(behaviour.meta)
    end

    function client:start()
        record("start")
        return behaviour.graves or { cards = {}, notes = {}, decks = {} }
    end

    function client:apply_changes()
        record("applyChanges")
        return behaviour.changes or { models = {}, decks = { {}, {} }, tags = {} }
    end

    function client:chunk()
        record("chunk")
        local next_chunk = table.remove(behaviour.chunks or {}, 1)
        return next_chunk or { done = true }
    end

    function client:apply_chunk(chunk)
        local ok, err = record("applyChunk")
        if not ok then
            return nil, err
        end
        behaviour.pushed = behaviour.pushed or {}
        behaviour.pushed[#behaviour.pushed + 1] = chunk
        return true
    end

    function client:sanity_check2()
        record("sanityCheck2")
        return resolve(behaviour.sanity) or "ok"
    end

    function client:finish()
        record("finish")
        return behaviour.finish_mod or 12345
    end

    function client:download()
        record("download")
        return behaviour.download_body
    end

    function client:upload()
        record("upload")
        return true
    end

    return client
end

return {
    ["no local changes returns noChanges without asking the server further"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local calls = {}
            local runner = Runner.new{
                collection = collection,
                client = fake_client({
                    meta = { mod = collection.modified, scm = collection.schema_modified },
                }, calls),
            }
            local result = runner:sync()
            assert(result.status == "noChanges", result.status)
            assert(#calls == 1 and calls[1] == "meta", table.concat(calls, ","))
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["schema mismatch adopts the server copy and keeps local reviews"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local input = assert(io.open(FIXTURE, "rb"))
        local server_bytes = input:read("*a")
        input:close()

        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local card = collection:cards_in_decks({ NEW_DECK })[1]
            assert(card, "fixture has no cards")
            -- One card reviewed offline: it must survive the download.
            collection.conn:run("update cards set usn = -1 where id = ?", card.id)
            -- Local schema is ahead of the server's copy (the reported loop).
            local server_scm = collection.schema_modified
            collection.conn:run("update col set scm = ?", server_scm + 5000)
            collection.schema_modified = server_scm + 5000

            local base = Helpers.root .. "/../out/adopt-" .. tostring(os.time())
                .. "-" .. tostring(math.random(100000))
            local paths = Paths.new(base, base .. "/settings")
            assert(Paths.ensure(paths))

            local calls = {}
            local behaviour = {
                -- The server copy keeps the original scm.
                meta = function()
                    return { mod = 999, scm = server_scm, usn = 7 }
                end,
                download_body = server_bytes,
                finish_mod = 4321,
            }
            local runner = Runner.new{
                collection = collection,
                client = fake_client(behaviour, calls),
                paths = paths,
            }
            local result = runner:sync()
            assert(result.status == "normal",
                tostring(result.status) .. " " .. tostring(result.message))
            assert(calls[1] == "meta" and calls[2] == "download",
                table.concat(calls, ","))

            local row = collection.conn:first(
                "select usn from cards where id = ?", card.id)
            assert(row and tonumber(row[1]) ~= -1, "the local review stayed pending")
            local pushed = behaviour.pushed or {}
            local found = false
            for _, chunk in ipairs(pushed) do
                for _, pushed_card in ipairs(chunk.cards or {}) do
                    if tonumber(pushed_card[1]) == tonumber(card.id) then
                        found = true
                    end
                end
            end
            assert(found, "the replayed card was not pushed to the server")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["sanity mismatch adopts the server copy instead of giving up"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local input = assert(io.open(FIXTURE, "rb"))
        local server_bytes = input:read("*a")
        input:close()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local base = Helpers.root .. "/../out/sanity-" .. tostring(os.time())
                .. "-" .. tostring(math.random(100000))
            local paths = Paths.new(base, base .. "/settings")
            assert(Paths.ensure(paths))
            local calls = {}
            local sanity_calls = 0
            local behaviour = {
                meta = { mod = 999, scm = collection.schema_modified, usn = 1 },
                sanity = function()
                    sanity_calls = sanity_calls + 1
                    return sanity_calls == 1 and "bad" or "ok"
                end,
                download_body = server_bytes,
                finish_mod = 2222,
            }
            local runner = Runner.new{
                collection = collection,
                client = fake_client(behaviour, calls),
                paths = paths,
            }
            local result = runner:sync()
            assert(result.status == "normal",
                tostring(result.status) .. " " .. tostring(result.message))
            local saw_download = false
            for _, name in ipairs(calls) do
                if name == "download" then
                    saw_download = true
                end
            end
            assert(saw_download, "sanity failure did not re-download the collection")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["a failed push leaves the rows pending"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local card = collection:cards_in_decks({ NEW_DECK })[1]
            collection.conn:run("update cards set usn = -1 where id = ?", card.id)
            local calls = {}
            local behaviour = {
                meta = { mod = 999, scm = collection.schema_modified, usn = 3 },
                error_at = "applyChunk",
            }
            local runner = Runner.new{
                collection = collection,
                client = fake_client(behaviour, calls),
            }
            local result = runner:sync()
            assert(result.status == "error", result.status)
            local row = collection.conn:first(
                "select usn from cards where id = ?", card.id)
            assert(row and tonumber(row[1]) == -1,
                "a failed push marked the review as sent (usn=" .. tostring(row and row[1]) .. ")")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["normal sync pulls, pushes pending rows and records finish"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()

        -- Make one local card pending, as a review would.
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local card = collection:cards_in_decks({ NEW_DECK })[1]
            assert(card, "fixture has no cards")
            collection.conn:run("update cards set usn = -1 where id = ?", card.id)

            local server_note = {
                id = 987654321,
                guid = "abc",
                mid = collection:note(card.nid).mid,
                mod = os.time(),
                usn = 5,
                tags = "",
                flds = "front\31back",
                sfld = 0,
                csum = 0,
                flags = 0,
                data = "",
            }
            local server_card = {
                id = 987654322,
                nid = server_note.id,
                did = card.did,
                ord = 0,
                mod = os.time(),
                usn = 5,
                type = 0,
                queue = 0,
                due = 100,
                ivl = 0,
                factor = 0,
                reps = 0,
                lapses = 0,
                left = 0,
                odue = 0,
                odid = 0,
                flags = 0,
                data = "",
            }
            local inbound = {
                done = false,
                cards = { protocol.card_row(server_card, 5) },
                notes = { protocol.note_row(server_note, 5) },
                revlog = {},
            }

            local behaviour = {
                meta = { mod = 999, scm = collection.schema_modified, usn = 7 },
                chunks = { inbound },
                finish_mod = 4321,
            }
            local calls = {}
            local runner = Runner.new{
                collection = collection,
                client = fake_client(behaviour, calls),
            }
            local result = runner:sync()
            assert(result.status == "normal", result.status .. " " .. tostring(result.message))
            assert(collection.ls == 4321, "col.ls not updated")
            assert(collection.conn:first("select id from cards where id = 987654322"),
                "inbound card was not applied")
            assert(collection.conn:first("select id from notes where id = 987654321"),
                "inbound note was not applied")
            local still_pending = collection.conn:first("select usn from cards where id = ?", card.id)
            assert(still_pending and tonumber(still_pending[1]) ~= -1, "local card still pending")
            assert(#(behaviour.pushed or {}) >= 1, "nothing was pushed")

            -- The pushed row must be the real card.  The old encoder was fed
            -- positional DB rows, read `row.id`/`row.nid` as nil, and uploaded
            -- a zero row that the server happily accepted.
            local pushed = behaviour.pushed[1]
            local pushed_card = (pushed.cards or {})[1]
            assert(pushed_card, "no card in the pushed chunk")
            assert(tonumber(pushed_card[1]) == tonumber(card.id),
                "pushed card id: " .. tostring(pushed_card[1]))
            assert(tonumber(pushed_card[5]) == tonumber(card.mod),
                "pushed card mod: " .. tostring(pushed_card[5]))
            assert(tonumber(pushed_card[6]) ~= -1, "pushed card usn is -1")
            assert(tonumber(pushed_card[2]) == tonumber(card.nid),
                "pushed card nid: " .. tostring(pushed_card[2]))

            -- BLOB storage class for the incoming card's protobuf `data`.
            local column = collection.conn:first(
                "select typeof(data) from cards where id = ?", server_card.id)
            assert(column and column[1] == "blob",
                "inbound card data stored as " .. tostring(column and column[1]))
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["a network error is reported instead of raising"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local calls = {}
            local runner = Runner.new{
                collection = collection,
                client = fake_client({ error_at = "meta" }, calls),
            }
            local result = runner:sync()
            assert(result.status == "error", result.status)
            assert(type(result.message) == "string" and #result.message > 0)
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["full download works before a local collection exists"] = function()
        if not FIXTURE then
            return
        end
        -- The device hit both halves of this: the data directory did not exist
        -- (`cantopen`) and the download branch used to open an empty placeholder
        -- (`collection has no col row`).  A first sync must do neither.
        local input = assert(io.open(FIXTURE, "rb"))
        local bytes = input:read("*a")
        input:close()

        local base = Helpers.root .. "/../out/download-" .. tostring(os.time())
            .. "-" .. tostring(math.random(100000))
        local paths = Paths.new(base, base .. "/settings")
        assert(Paths.ensure(paths))

        local runner = Runner.new{
            collection = nil,
            client = { download = function() return bytes end },
            paths = paths,
        }
        local ok, err = runner:full_download()
        assert(ok, "full_download failed: " .. tostring(err))

        local collection = Collection.open(paths.collection)
        assert(collection, "downloaded collection cannot be opened")
        local count = collection.conn:first("select count(*) from cards")
        assert(count and tonumber(count[1]) > 0, "downloaded collection is empty")
        collection:close()

        os.remove(paths.collection)
        os.remove(base .. "/collection.incoming")
        os.remove(paths.collection .. ".bak")
    end,
}
