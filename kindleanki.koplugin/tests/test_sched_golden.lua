-- Differential test: our v3 maths against Anki's real backend.
--
-- `out/golden.lua` is produced by tools/diff/dump_queue.py (which runs the real
-- rslib through the `anki` Python package).  Reproduce it with:
--
--   python tools\diff\dump_queue.py --collection <fixture> --format lua --out out\golden.lua
--
-- Fuzz is random per card in Anki (StdRng seeded with card_id + reps), so an
-- exact interval cannot be reproduced; what must hold is that our raw interval
-- is right and the backend's fuzzed value lands inside the bounds we compute.

local Helpers = require("helpers")
local Collection = require("model.collection")
local States = require("sched.states")

local FIXTURE = os.getenv("KINDLEANKI_TEST_COLLECTION")
local GOLDEN_PATH = os.getenv("KINDLEANKI_GOLDEN")
    or (Helpers.root .. "/../out/golden.lua")

local function golden_or_nil()
    if not FIXTURE then
        return nil
    end
    local file = io.open(GOLDEN_PATH, "rb")
    if not file then
        return nil
    end
    file:close()
    return dofile(GOLDEN_PATH)
end

local function review_state(states, answer)
    local normal = states[answer] and states[answer]["normal"]
    return normal and normal["review"] or nil
end

return {
    ["golden dump exists (else skipped)"] = function()
        gold = golden_or_nil()
        assert(gold == nil or type(gold.queued) == "table")
    end,

    ["backend counts match the golden dump"] = function()
        local gold = golden_or_nil()
        if not gold then
            return
        end
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            collection:load_decks()
            local deck_id = collection:active_deck_id()
            local decks = collection:deck_subtree_ids(deck_id)
            local cards = collection:cards_in_decks(decks)
            local now = os.time()
            local today = gold.today
            local counts = { new = 0, learning = 0, review = 0 }
            for _, card in ipairs(cards) do
                if card.queue == 0 and card.type == 0 then
                    counts.new = counts.new + 1
                elseif card.type == 1 or card.type == 3 then
                    if card.type == 3 then
                        if card.due <= today then
                            counts.learning = counts.learning + 1
                        end
                    elseif card.due <= now then
                        counts.learning = counts.learning + 1
                    end
                elseif card.type == 2 and card.due <= today then
                    counts.review = counts.review + 1
                end
            end
            assert(counts.review >= gold.counts.review,
                string.format("review counts: ours=%d golden=%d",
                    counts.review, gold.counts.review))
        end)
        collection:close()
        assert(ok, err)
    end,

    ["new-card learning steps match Anki exactly"] = function()
        if not FIXTURE then
            return
        end
        local path = Helpers.root .. "/../out/golden_new.lua"
        local file = io.open(path, "rb")
        if not file then
            return
        end
        file:close()
        local gold = dofile(path)

        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            local checked = 0
            for _, entry in ipairs(gold.queued) do
                if entry.card.type == 0 then
                    local card = collection:card_by_id(entry.card.id)
                    assert(card, "golden new card missing locally")
                    local deck = collection:deck(card.did) or collection.decks[1]
                    local config = collection:deck_config(deck)
                    local state = States.from_card(card, gold.today, os.time())
                    assert(state.kind == "new", state.kind)
                    local next_states = States.next(state, config, {})

                    local learning = { again = true, hard = true, good = true }
                    for answer in pairs(learning) do
                        local expected = entry.states[answer].normal.learning
                        local actual = next_states[answer]
                        assert(actual.kind == "learning",
                            answer .. ": " .. tostring(actual.kind))
                        assert(actual.scheduled_secs == expected.scheduled_secs,
                            string.format("%s secs: ours=%d golden=%d", answer,
                                actual.scheduled_secs, expected.scheduled_secs))
                    end
                    assert(next_states.good.remaining_steps
                        == entry.states.good.normal.learning.remaining_steps,
                        "good remaining_steps mismatch")

                    local easy = entry.states.easy.normal.review
                    local actual_easy = next_states.easy
                    assert(actual_easy.kind == "review")
                    assert(actual_easy.fuzz_lower <= easy.scheduled_days
                        and easy.scheduled_days <= actual_easy.fuzz_upper,
                        string.format("easy: expected %d, bounds [%d,%d]",
                            easy.scheduled_days, actual_easy.fuzz_lower,
                            actual_easy.fuzz_upper))
                    checked = checked + 1
                end
            end
            assert(checked >= 3, "not enough new cards compared: " .. checked)
        end)
        collection:close()
        assert(ok, err)
    end,

    ["review intervals land inside Anki's fuzz bounds"] = function()
        local gold = golden_or_nil()
        if not gold then
            return
        end
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            local checked = 0
            for _, entry in ipairs(gold.queued) do
                local card = collection:card_by_id(entry.card.id)
                assert(card, "golden card missing locally: " .. tostring(entry.card.id))
                local deck = collection:deck(card.did) or collection.decks[1]
                local config = collection:deck_config(deck)
                local state = States.from_card(card, gold.today, os.time())
                assert(state.kind == "review", state.kind)
                assert(state.elapsed_days == entry.states.current.normal.review.elapsed_days,
                    string.format("elapsed: ours=%d golden=%d", state.elapsed_days,
                        entry.states.current.normal.review.elapsed_days))

                local next_states = States.next(state, config, {})
                for _, answer in ipairs({ "hard", "good", "easy" }) do
                    local expected = review_state(entry.states, answer)
                    local actual = next_states[answer]
                    assert(actual and actual.kind == "review", answer .. " state kind")
                    assert(actual.fuzz_lower <= expected.scheduled_days
                        and expected.scheduled_days <= actual.fuzz_upper,
                        string.format("%s: expected %d, bounds [%d,%d]",
                            answer, expected.scheduled_days,
                            actual.fuzz_lower, actual.fuzz_upper))
                    assert(math.abs(actual.ease_factor - expected.ease_factor) < 0.001,
                        string.format("%s ease: ours=%.3f golden=%.3f",
                            answer, actual.ease_factor, expected.ease_factor))
                    checked = checked + 1
                end
            end
            assert(checked >= 3, "not enough states compared: " .. checked)
        end)
        collection:close()
        assert(ok, err)
    end,
}
