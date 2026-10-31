-- Answer persistence and queue mechanics against a writable copy of a real
-- collection.  Never touches the fixture: it is copied to a temp file first.

local Helpers = require("helpers")
local Collection = require("model.collection")
local Session = require("study.session")
local Queue = require("sched.queue")

local FIXTURE = os.getenv("KINDLEARNKI_TEST_COLLECTION")
local NEW_DECK = tonumber(os.getenv("KINDLEARNKI_NEW_DECK") or "1782139166456")

local function copy_file(source, target)
    local input = assert(io.open(source, "rb"), "cannot open " .. source)
    local data = input:read("*a")
    input:close()
    local output = assert(io.open(target, "wb"), "cannot write " .. target)
    output:write(data)
    output:close()
end

local function copy_fixture()
    assert(FIXTURE, "KINDLEARNKI_TEST_COLLECTION is not set")
    local suffix = tostring(os.time()) .. "-" .. tostring(math.random(100000))
    local target = Helpers.root .. "/../out/test-" .. suffix .. ".anki2"
    os.remove(target)
    for _, extension in ipairs({ "", "-wal", "-shm" }) do
        local file = io.open(FIXTURE .. extension, "rb")
        if file then
            file:close()
            copy_file(FIXTURE .. extension, target .. extension)
        end
    end
    return target
end

local function cleanup(path)
    for _, extension in ipairs({ "", "-wal", "-shm" }) do
        os.remove(path .. extension)
    end
end

return {
    ["queue builds with limits and counts"] = function()
        if not FIXTURE then
            return
        end
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            local now = os.time()
            local today = collection:days_elapsed(now)
            local built = Queue.build(collection, collection:active_deck_id(),
                { now = now, today = today })
            assert(type(built.cards) == "table")
            assert(built.counts.review >= 1, "expected due reviews in the active deck")
            -- Ordering invariant: learning cards never come after reviews.
            local seen_review = false
            for _, card in ipairs(built.cards) do
                if card.type == 2 then
                    seen_review = true
                elseif seen_review and card.type == 1 then
                    error("intraday learning card after a review card")
                end
            end
        end)
        collection:close()
        assert(ok, err)
    end,

    ["answering a new card persists card, revlog and counters"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local session = Session.new{
                collection = collection,
                deck_id = NEW_DECK,
                now = os.time(),
            }
            assert(session:remaining() > 0, "no cards in the new-card session")
            -- The queue may legitimately start with due learning/review cards;
            -- skip forward until the first new card, answering as we go.
            local item = session:next()
            local guard = 0
            local watch = #session.queue.cards + 5
            while item and item.card.type ~= 0 and guard < watch do
                session:answer(3)
                item = session:next()
                guard = guard + 1
            end
            assert(item and item.card, "no first item")
            assert(item.card.type == 0, "expected a new card, got type "
                .. tostring(item.card and item.card.type))

            local before_new = session.done
            local result = session:answer(3, { time_ms = 1200 })
            assert(result and result.card, "answer returned nothing")
            assert(result.card.type == 1 or result.card.type == 2,
                "answered new card should be learning or review, got " .. tostring(result.card.type))
            assert(session.done == before_new + 1)

            local revlog = collection.conn:first(
                "select count(*) from revlog where cid = ?", item.card.id)
            assert(tonumber(revlog[1]) >= 1, "revlog row missing")

            local card = collection:card_by_id(item.card.id)
            assert(card.reps == item.card.reps + 1, "reps not incremented")
            assert(card.usn == -1, "card should be marked for sync")
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["\u{201c}again\u{201d} keeps a learning card inside the session"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local session = Session.new{
                collection = collection,
                deck_id = NEW_DECK,
                now = os.time(),
            }
            local item = session:next()
            local guard = 0
            local watch = #session.queue.cards + 5
            while item and item.card.type ~= 0 and guard < watch do
                session:answer(3)
                item = session:next()
                guard = guard + 1
            end
            assert(item and item.card.type == 0, "no new card to answer")
            local before = session:remaining()
            local result = session:answer(1) -- again
            assert(result.card.type == 1, "again on a new card stays in learning")
            assert(session:remaining() >= before,
                string.format("learning card should be re-queued: before=%d after=%d",
                    before, session:remaining()))
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,

    ["session drains without errors"] = function()
        if not FIXTURE then
            return
        end
        local path = copy_fixture()
        local collection = Collection.open(path)
        local ok, err = pcall(function()
            collection:load_decks()
            local session = Session.new{
                collection = collection,
                deck_id = NEW_DECK,
                now = os.time(),
            }
            local answered = 0
            while answered < 4 do
                local item = session:next()
                if not item then
                    break
                end
                session:answer(3)
                answered = answered + 1
            end
            assert(answered >= 1, "session answered nothing")
            assert(session.done == answered)
        end)
        collection:close()
        cleanup(path)
        assert(ok, err)
    end,
}


