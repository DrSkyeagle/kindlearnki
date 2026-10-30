-- Differential test: our v3 maths against Anki's real backend.
--
-- `out/golden.lua` and `out/golden_new.lua` are produced by
-- tools/diff/dump_queue.py (which runs the real rslib through the `anki`
-- Python package).  Regenerate BOTH whenever the fixture collection is
-- replaced/re-downloaded: the goldens are a snapshot of the fixture's cards,
-- deck counters and `today`, so a new download invalidates them.  The exact
-- commands (from tools/diff/README.md) are:
--
--   python tools\diff\dump_queue.py --collection <fixture> --deck 1784512477702 --limit 6 --format lua --out out\golden.lua
--   python tools\diff\dump_queue.py --collection <fixture> --deck 1782139166456 --limit 12 --format lua --out out\golden_new.lua
--
-- The dump tool auto-repairs a fixture whose writer stored a BLOB-declared
-- column (e.g. decks.common) as TEXT: rslib reads those as Vec<u8> and rejects
-- TEXT with `DBError { info: "InvalidType" }`, which would make the whole
-- collection unreadable to the reference backend.  The repair happens on the
-- dump tool's temporary copy only (logged as FIXTURE-SANITIZED), and the golden
-- records the fixture's crt/mod so a stale dump is detected here instead of
-- being blamed on the scheduler.
--
-- Robustness rules -- every skip is counted and printed, never silent:
--   * `today` is derived the way Anki does (collection:days_elapsed(now)),
--     not from a bare `os.date` day, and is floored at the golden's snapshot
--     day.  Counts assertions are lower bounds because time only moves
--     forward: every review card that was due when rslib recorded the golden
--     (due <= gold.today) is still due when `today >= gold.today`.
--   * An entry whose local card is no longer in the state the golden recorded
--     (e.g. a new card that has since been studied / became due) is skipped
--     with a printed reason and counted.
--   * If the fixture's crt/mod no longer match the golden snapshot, the
--     golden-dependent comparison is skipped with a "regenerate" message.
--
-- Fuzz is random per card in Anki (StdRng seeded with card_id + reps), so an
-- exact interval cannot be reproduced; what must hold is that our raw interval
-- is right and the backend's fuzzed value lands inside the bounds we compute.

local Helpers = require("helpers")
local Collection = require("model.collection")
local States = require("sched.states")

local FIXTURE = os.getenv("KINDLEANKI_TEST_COLLECTION")
local GOLDEN_DIR = Helpers.root .. "/../out"

local function report(fmt, ...)
    print("sched_golden: " .. string.format(fmt, ...))
end

local function load_golden(name)
    local path = GOLDEN_DIR .. "/" .. name
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    file:close()
    return dofile(path)
end

--- True when the fixture on disk is no longer the snapshot the golden was
--- taken from.  Old goldens (before crt/mod were recorded) are treated as
--- matching so they stay usable.
local function snapshot_changed(gold, collection)
    if type(gold.crt) ~= "number" or type(gold.mod) ~= "number" then
        return false
    end
    return tonumber(collection.created) ~= gold.crt
        or tonumber(collection.modified) ~= gold.mod
end

local function review_state(states, answer)
    local normal = states[answer] and states[answer]["normal"]
    return normal and normal["review"] or nil
end

return {
    ["golden dump exists (else skipped)"] = function()
        local gold = load_golden("golden.lua")
        assert(gold == nil or type(gold.queued) == "table")
    end,

    ["backend counts match the golden dump"] = function()
        if not FIXTURE then
            return
        end
        local gold = load_golden("golden.lua")
        if not gold then
            return
        end
        assert(type(gold.queued) == "table" and #gold.queued > 0,
            "golden dump has no queued cards: regenerate out/golden.lua")
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            collection:load_decks()
            if snapshot_changed(gold, collection) then
                report("SKIP counts: fixture changed since golden dump (crt/mod), regenerate out/golden.lua")
                return
            end
            -- The golden's counts belong to `gold.deck` (the deck the dump
            -- selected); for goldens that predate the field, the collection's
            -- active deck was what the backend counted.
            local deck_id = gold.deck or collection:active_deck_id()
            local cards = collection:cards_in_decks(collection:deck_subtree_ids(deck_id))
            local now = os.time()
            -- Anki's v3 days_elapsed (crt + rollover + offsets), not a bare
            -- wall-clock day.  Floor at the snapshot day: a re-downloaded
            -- collection can carry an older crt, and going backwards would
            -- break the lower-bound comparison below.  (days_elapsed also
            -- returns "next day at" as a second value; take only the day.)
            local derived_today = collection:days_elapsed(now)
            local today = math.max(gold.today, derived_today)
            local counts = { new = 0, learning = 0, review = 0 }
            for _, card in ipairs(cards) do
                if card.type == 0 and card.queue == 0 then
                    counts.new = counts.new + 1
                elseif card.type == 1 and card.queue == 1 then
                    -- Learning cards store `due` as a unix timestamp.
                    if card.due <= now then
                        counts.learning = counts.learning + 1
                    end
                elseif card.type == 3 and card.queue == 3 then
                    -- Relearning: `due` is a unix timestamp as well, not a day
                    -- number (comparing it to `today` would never be true).
                    if card.due <= now then
                        counts.learning = counts.learning + 1
                    end
                elseif card.type == 2 and card.queue == 2 and card.due <= today then
                    counts.review = counts.review + 1
                end
            end
            -- The golden was recorded by rslib on this same snapshot at
            -- `gold.today`.  A review card is due once `due <= today`, and
            -- `today` only advances, so every card the backend counted is due
            -- now too: the local count is a LOWER BOUND (equality is expected
            -- only when the clock has not crossed rollover since the dump).
            assert(counts.review >= gold.counts.review,
                string.format(
                    "review counts: ours=%d golden=%d (deck=%s today=%d golden_today=%d)",
                    counts.review, gold.counts.review, tostring(deck_id), today, gold.today))
            report("counts deck=%s review=%d>=%d new=%d learning=%d today=%d golden_today=%d",
                tostring(deck_id), counts.review, gold.counts.review,
                counts.new, counts.learning, today, gold.today)
        end)
        collection:close()
        assert(ok, err)
    end,

    ["new-card learning steps match Anki exactly"] = function()
        if not FIXTURE then
            return
        end
        local gold = load_golden("golden_new.lua")
        if not gold then
            return
        end
        assert(type(gold.queued) == "table" and #gold.queued > 0,
            "golden_new dump has no queued cards: regenerate out/golden_new.lua")

        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            collection:load_decks()
            local stale = snapshot_changed(gold, collection)
            local now = os.time()
            local checked, skipped = 0, 0
            for _, entry in ipairs(gold.queued) do
                if entry.card.type == 0 then
                    local card = collection:card_by_id(entry.card.id)
                    local state = card and States.from_card(card, gold.today, now)
                    if not state then
                        skipped = skipped + 1
                        report("new-card skip: card %s missing locally", tostring(entry.card.id))
                    elseif state.kind ~= "new" then
                        -- The fixture can legitimately move a card out of New
                        -- between the dump and this run (it was studied or came
                        -- due on another device); the golden's learning steps no
                        -- longer apply to this card.  Counted and printed, never
                        -- silently dropped.
                        skipped = skipped + 1
                        report("new-card skip: card %s is now %s, not new",
                            tostring(entry.card.id), tostring(state.kind))
                    else
                        local deck = collection:deck(card.did) or collection.decks[1]
                        local config = collection:deck_config(deck)
                        -- The golden's scheduled_secs come from the deck config
                        -- at dump time.  If that config changed since (possible
                        -- after a re-download) the right move is to skip the
                        -- entry with a reason instead of blaming the maths.
                        local expected_again = entry.states.again.normal.learning.scheduled_secs
                        local expected_good = entry.states.good.normal.learning.scheduled_secs
                        local expected_count = entry.states.good.normal.learning.remaining_steps + 1
                        local same_config = #config.learn_steps == expected_count
                            and math.floor(config.learn_steps[1] * 60 + 0.5) == expected_again
                            and math.floor(config.learn_steps[#config.learn_steps] * 60 + 0.5)
                                == expected_good
                        if not same_config then
                            skipped = skipped + 1
                            report("new-card skip: card %s deck config changed since dump",
                                tostring(entry.card.id))
                        else
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
                end
            end
            report("new-card steps queued=%d checked=%d skipped=%d",
                #gold.queued, checked, skipped)
            if checked < 3 then
                if stale or skipped > 0 then
                    -- Either the fixture was re-downloaded/rewritten, or enough
                    -- cards moved state that the golden's new-card cohort is no
                    -- longer representative.  Loud, counted skip -- the
                    -- comparable entries above still had to pass their asserts.
                    report("SKIP new-card steps: only %d comparable of %d examined"
                        .. " (%d skipped); regenerate out/golden_new.lua",
                        checked, #gold.queued, skipped)
                    return
                end
                -- Nothing was skipped, yet fewer than 3 golden New cards were
                -- compared: either the dump is empty/broken or our reader no
                -- longer recognises the golden's New cards.  Both are failures.
                assert(false, string.format(
                    "not enough new cards compared: queued=%d checked=%d skipped=%d",
                    #gold.queued, checked, skipped))
            end
        end)
        collection:close()
        assert(ok, err)
    end,

    ["review intervals land inside Anki's fuzz bounds"] = function()
        if not FIXTURE then
            return
        end
        local gold = load_golden("golden.lua")
        if not gold then
            return
        end
        assert(type(gold.queued) == "table" and #gold.queued > 0,
            "golden dump has no queued cards: regenerate out/golden.lua")
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            collection:load_decks()
            if snapshot_changed(gold, collection) then
                report("SKIP review intervals: fixture changed since golden dump (crt/mod), regenerate out/golden.lua")
                return
            end
            local now = os.time()
            local checked, skipped = 0, 0
            for _, entry in ipairs(gold.queued) do
                local card = collection:card_by_id(entry.card.id)
                local state = card and States.from_card(card, gold.today, now)
                if not state then
                    skipped = skipped + 1
                    report("review skip: card %s missing locally", tostring(entry.card.id))
                elseif state.kind ~= "review" then
                    -- Same idea as for new cards: if the collection moved this
                    -- card to another state, the recorded review maths no
                    -- longer applies to it.
                    skipped = skipped + 1
                    report("review skip: card %s is now %s, not review",
                        tostring(entry.card.id), tostring(state.kind))
                else
                    local deck = collection:deck(card.did) or collection.decks[1]
                    local config = collection:deck_config(deck)
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
            end
            report("review intervals queued=%d checked=%d skipped=%d",
                #gold.queued, checked, skipped)
            if checked < 3 then
                if skipped > 0 then
                    -- Cards moved to another state since the dump; the reviewed
                    -- entries above still had to pass their asserts.  Loud,
                    -- counted skip instead of blaming the scheduler.
                    report("SKIP review intervals: only %d comparable of %d"
                        .. " examined (%d skipped); regenerate out/golden.lua",
                        checked, #gold.queued, skipped)
                    return
                end
                assert(false, string.format(
                    "not enough states compared: queued=%d checked=%d skipped=%d",
                    #gold.queued, checked, skipped))
            end
        end)
        collection:close()
        assert(ok, err)
    end,
}
