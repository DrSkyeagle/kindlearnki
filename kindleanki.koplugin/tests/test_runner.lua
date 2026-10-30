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

local FIXTURE = os.getenv("KINDLEANKI_TEST_COLLECTION")
local NEW_DECK = tonumber(os.getenv("KINDLEANKI_NEW_DECK") or "1782139166456")

local function copy_fixture()
    assert(FIXTURE, "KINDLEANKI_TEST_COLLECTION is not set")
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
local function fake_client(behaviour, calls)
    local client = {}
    local function record(name)
        calls[#calls + 1] = name
        if behaviour.error_at == name then
            return nil, "network down"
        end
        return true
    end

    function client:meta()
        record("meta")
        return behaviour.meta
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
        record("applyChunk")
        behaviour.pushed = behaviour.pushed or {}
        behaviour.pushed[#behaviour.pushed + 1] = chunk
        return true
    end

    function client:sanity_check2()
        record("sanityCheck2")
        return behaviour.sanity or "ok"
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

    ["schema mismatch asks for a full sync"] = function()
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
                    meta = { mod = 1, scm = (collection.schema_modified or 0) + 1 },
                }, calls),
            }
            local result = runner:sync()
            assert(result.status == "fullRequired", result.status)
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
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["sanity failure asks for a full sync"] = function()
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
                    meta = { mod = 999, scm = collection.schema_modified, usn = 1 },
                    sanity = "bad",
                }, calls),
            }
            local result = runner:sync()
            assert(result.status == "fullRequired", result.status)
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
