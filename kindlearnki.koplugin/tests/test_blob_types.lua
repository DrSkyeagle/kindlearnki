-- BLOB storage class of the columns we write.
--
-- Regression for a real bug: `update decks set common = ?` handed the
-- Deck.Common protobuf to lua-ljsqlite3 as a plain Lua string, which binds it
-- as TEXT.  Rows then had typeof(common) = 'text' even though the schema
-- declares the column BLOB.  This reader accepts both classes (SQLite returns
-- TEXT as a string and BLOB as {ptr, size}, and db/conn.lua normalises both),
-- so nothing looked wrong here -- but Anki's rslib reads the column as
-- `Vec<u8>` and fails with InvalidType, i.e. a collection we wrote could not
-- be opened by Anki at all.
--
-- The fixture is only ever read: every writing case works on a copy under
-- out/tmp/ (point the suite at a collection with KINDLEARNKI_TEST_COLLECTION).

local Helpers = require("helpers")
local Collection = require("model.collection")
local Conn = require("db.conn")
local PB = require("proto.pb")
local Queue = require("sched.queue")
local Store = require("sync.store")

local FIXTURE = os.getenv("KINDLEARNKI_TEST_COLLECTION")
-- run.lua creates this scratch directory before loading any test file; cases
-- here only ever write below it, never to the fixture itself.
local TMP_DIR = Helpers.root .. "/../out/tmp"

local function copy_fixture()
    assert(FIXTURE, "KINDLEARNKI_TEST_COLLECTION is not set")
    local suffix = tostring(os.time()) .. "-" .. tostring(math.random(100000))
    local target = TMP_DIR .. "/blob-" .. suffix .. ".anki2"
    for _, extension in ipairs({ "", "-wal", "-shm" }) do
        local input = io.open(FIXTURE .. extension, "rb")
        if input then
            local data = input:read("*a")
            input:close()
            local output = assert(io.open(target .. extension, "wb"),
                "cannot write " .. target .. extension)
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

--- First deck of the fixture (deck 1 is Anki's default deck).
local function first_deck(collection)
    collection:load_decks()
    return collection:deck(1) or collection.decks[1]
end

return {
    ["schema declares the written protobuf columns as BLOB"] = function()
        if not FIXTURE then
            return
        end
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            -- `pragma table_info` reports the declared type, which is what
            -- sqlite affinity (and rslib's Vec<u8> decoding) is based on.
            local declared = {}
            for _, row in ipairs(collection.conn:all("pragma table_info(decks)")) do
                declared[tostring(row[2])] = tostring(row[3]):lower()
            end
            assert(declared.common == "blob", "decks.common is " .. tostring(declared.common))
            assert(declared.kind == "blob", "decks.kind is " .. tostring(declared.kind))
            for _, spec in ipairs({
                { "deck_config", "config" },
                { "notetypes", "config" },
                { "templates", "config" },
                { "fields", "config" },
                { "config", "val" },
            }) do
                local found
                for _, row in ipairs(collection.conn:all(
                    "pragma table_info(" .. spec[1] .. ")")) do
                    if tostring(row[2]) == spec[2] then
                        found = tostring(row[3]):lower()
                    end
                end
                assert(found == "blob",
                    spec[1] .. "." .. spec[2] .. " is " .. tostring(found))
            end
        end)
        collection:close()
        assert(ok, err)
    end,

    ["Conn.blob binds a BLOB while a plain string binds TEXT"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection.conn:exec("create table blob_probe(x blob)")
            collection.conn:run("insert into blob_probe values(?)", "plain-text-bytes")
            collection.conn:run("insert into blob_probe values(?)",
                Conn.blob("real-blob-bytes"))
            local rows = collection.conn:all(
                "select typeof(x), x from blob_probe order by rowid")
            assert(#rows == 2, #rows)
            assert(rows[1][1] == "text",
                "plain string should stay TEXT, got " .. tostring(rows[1][1]))
            assert(rows[2][1] == "blob",
                "Conn.blob should bind BLOB, got " .. tostring(rows[2][1]))
            assert(rows[2][2] == "real-blob-bytes", "blob bytes must round-trip")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["bump_studied writes decks.common as a BLOB"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local deck = first_deck(collection)
            assert(deck, "fixture has no decks")
            assert(type(deck.common_blob) == "string",
                "fixture deck has no Deck.Common payload")

            local today = collection:days_elapsed(os.time())
            Queue.bump_studied(collection, deck.id, today, "new")

            local row = collection.conn:first(
                "select typeof(common), common from decks where id = ?", deck.id)
            assert(row, "deck row disappeared")
            assert(row[1] == "blob",
                "decks.common storage class is " .. tostring(row[1]))
            -- The payload must still be a valid Deck.Common carrying today.
            local common = PB.decode(row[2])
            assert(PB.uint(common, 3, 0) == today,
                string.format("last_day_studied=%d expected %d",
                    PB.uint(common, 3, 0), today))
            -- The other deck columns must not have changed class either.
            local kind = collection.conn:first(
                "select typeof(kind) from decks where id = ?", deck.id)
            assert(kind[1] == "blob", "decks.kind storage class is " .. tostring(kind[1]))
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["the reader keeps accepting legacy TEXT-typed blobs"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local original
        local ok, err = pcall(function()
            local deck = first_deck(collection)
            assert(deck, "fixture has no decks")
            original = deck.common_blob
            -- Reproduce what the old writer produced: identical bytes, TEXT
            -- storage class (Conn.blob is deliberately not used here).
            collection.conn:run("update decks set common = ? where id = ?",
                original, deck.id)
            local row = collection.conn:first(
                "select typeof(common) from decks where id = ?", deck.id)
            assert(row[1] == "text", "test setup failed: " .. tostring(row[1]))
            collection:close()

            local reopened = Collection.open(path, { read_only = true })
            local legacy = reopened:deck(deck.id)
            assert(legacy, "legacy deck row is no longer readable")
            assert(legacy.common_blob == original,
                "legacy TEXT bytes must decode like a BLOB")
            -- Counters are the only consumer of the payload.
            local counters = Queue.deck_counters(reopened, legacy)
            assert(type(counters.new_studied) == "number")
            reopened:close()
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["repair_blob_storage converts TEXT blobs back to BLOB"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local deck = first_deck(collection)
            assert(deck, "fixture has no decks")
            local original = deck.common_blob
            collection.conn:run("update decks set common = ? where id = ?",
                original, deck.id)

            local issues = collection:blob_storage_issues()
            assert(issues["decks.common"] and issues["decks.common"] >= 1,
                "expected at least one TEXT-typed decks.common")

            local repaired = collection:repair_blob_storage()
            assert(repaired >= 1, "repaired " .. tostring(repaired) .. " rows")

            local row = collection.conn:first(
                "select typeof(common), common from decks where id = ?", deck.id)
            assert(row[1] == "blob", "storage class is " .. tostring(row[1]))
            assert(row[2] == original, "repair must not change the protobuf bytes")

            local after = collection:blob_storage_issues()
            assert(not after["decks.common"],
                "decks.common still has " .. tostring(after["decks.common"]) .. " bad rows")

            -- A second run is a no-op (and must not open a transaction).
            assert(collection:repair_blob_storage() == 0)

            local check = collection.conn:first("pragma quick_check")
            assert(check and check[1] == "ok", "quick_check failed after repair")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["before_upload stamps scm into ls so the upload is self-consistent"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection.conn:run("update cards set usn = -1 where id = (select id from cards limit 1)")
            local usn_before = tonumber(collection.usn) or 0
            Store.before_upload(collection)
            local row = collection.conn:first("select scm, ls, usn from col")
            assert(row, "no col row")
            assert(row[1] == row[2],
                string.format("ls=%s is not scm=%s", tostring(row[2]), tostring(row[1])))
            assert(tonumber(row[3]) == usn_before + 1,
                string.format("usn %s was not incremented from %s",
                    tostring(row[3]), tostring(usn_before)))
            local pending = collection.conn:first(
                "select count(*) from cards where usn = -1")
            assert(tonumber(pending[1]) == 0, "pending cards survived before_upload")
            assert(collection.schema_modified == row[1],
                "in-memory scm was not refreshed")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["before_upload repairs blobs before the file leaves the device"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local deck = first_deck(collection)
            assert(deck, "fixture has no decks")
            collection.conn:run("update decks set common = ? where id = ?",
                deck.common_blob, deck.id)
            local before = collection.conn:first(
                "select typeof(common) from decks where id = ?", deck.id)
            assert(before[1] == "text", "test setup failed: " .. tostring(before[1]))

            Store.before_upload(collection)

            local after = collection.conn:first(
                "select typeof(common) from decks where id = ?", deck.id)
            assert(after[1] == "blob", "upload would carry TEXT: " .. tostring(after[1]))
            assert(not collection:blob_storage_issues()["decks.common"],
                "before_upload left legacy blobs behind")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["zero-length BLOB payloads are read back as empty strings"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            local deck = first_deck(collection)
            assert(deck, "fixture has no decks")
            -- Deck.Common defaults to an empty message, i.e. a zero-length
            -- BLOB; SQLite hands that back with a NULL pointer.
            collection.conn:run("update decks set common = ? where id = ?",
                Conn.blob(""), deck.id)
            collection:close()

            local reopened = Collection.open(path, { read_only = true })
            local empty = reopened:deck(deck.id)
            assert(empty, "deck row disappeared")
            assert(type(empty.common_blob) == "string",
                "empty BLOB payload is a " .. type(empty.common_blob)
                    .. " (copy_row left the {ptr, size} wrapper behind)")
            assert(empty.common_blob == "", "empty BLOB must read back as \"\"")
            local counters = Queue.deck_counters(reopened, empty)
            assert(counters.new_studied == 0 and counters.review_studied == 0)

            -- Every deck in the fixture must decode, including the ones whose
            -- common payload is legitimately empty.
            reopened:load_decks()
            for _, candidate in ipairs(reopened.decks) do
                assert(type(candidate.common_blob) == "string",
                    "deck " .. tostring(candidate.id) .. " payload is a "
                        .. type(candidate.common_blob))
                Queue.deck_counters(reopened, candidate)
            end
            reopened:close()
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["the writer binds the deck blob instead of interpolating it"] = function()
        local queue_source = Helpers.read("sched/queue.lua")
        assert(queue_source:find("Conn.blob(blob)", 1, true),
            "sched/queue.lua must bind the Deck.Common payload with Conn.blob")
        assert(queue_source:find("update decks set common = ?", 1, true),
            "decks.common must stay a ? parameter")
        -- No hex blob literal (x'..'), which would be string interpolation.
        assert(not queue_source:find("x'", 1, true),
            "unexpected hex BLOB literal in sched/queue.lua")

        local conn_source = Helpers.read("db/conn.lua")
        assert(conn_source:find("sqlite3_bind_blob", 1, true),
            "db/conn.lua must bind BLOBs through sqlite3_bind_blob")
        assert(conn_source:find("function Conn.blob", 1, true),
            "db/conn.lua must expose Conn.blob")
    end,
}
