-- v3 queue construction and daily limits.
--
-- Counts come from `decks.common` (Deck.Common.last_day_studied / new_studied /
-- review_studied), which is what rslib persists for v3 limits
-- (decks/counts.rs, decks/stats.rs).  Reading revlog instead would count cards
-- the desktop already studied on another device differently.
--
-- Ordering is the part of v3 this plugin deliberately simplifies: intraday
-- learning by due, then interday learning, then reviews by due, then new cards
-- by position.  v3 can interleave those (new_mix / interday_learning_mix); the
-- collections this targets use the defaults, and the differential test asserts
-- the *set* and the per-card states, not the interleaving.

local Conn = require("db.conn")
local PB = require("proto.pb")
local Encode = require("proto.encode")

local Queue = {}

--==========================================================================
-- Deck counters (decks.proto Deck.Common)
--==========================================================================

function Queue.deck_counters(collection, deck)
    local counters = { last_day = 0, new_studied = 0, review_studied = 0 }
    if not deck or not deck.common_blob then
        return counters
    end
    local common = PB.decode(deck.common_blob)
    counters.last_day = PB.uint(common, 3, 0)
    counters.new_studied = PB.uint(common, 4, 0)
    counters.review_studied = PB.uint(common, 5, 0)
    return counters
end

--- Sum counters over a deck subtree.
function Queue.subtree_counters(collection, deck_id)
    local totals = { last_day = 0, new_studied = 0, review_studied = 0 }
    for _, id in ipairs(collection:deck_subtree_ids(deck_id)) do
        local deck = collection:deck(id)
        local counters = Queue.deck_counters(collection, deck)
        if counters.last_day > totals.last_day then
            totals.last_day = counters.last_day
        end
        totals.new_studied = totals.new_studied + counters.new_studied
        totals.review_studied = totals.review_studied + counters.review_studied
    end
    return totals
end

--- Remaining new/review allowance for today.
function Queue.limits(collection, deck_id, today)
    local deck = collection:deck(deck_id)
    local config = collection:deck_config(deck)
    local counters = Queue.subtree_counters(collection, deck_id)
    if counters.last_day ~= today then
        counters.new_studied = 0
        counters.review_studied = 0
    end
    return {
        new = math.max(0, config.new_per_day - counters.new_studied),
        review = math.max(0, config.reviews_per_day - counters.review_studied),
    }
end

--==========================================================================
-- Classification
--==========================================================================

local function classify(card, now, today)
    if card.queue == -1 or card.queue == -2 or card.queue == -3 then
        return nil -- suspended or buried
    end
    if card.type == 0 and card.queue == 0 then
        return "new"
    end
    if card.type == 1 then
        return card.due <= now and "learning" or nil
    end
    if card.type == 3 then
        return card.due <= today and "interday_learning" or nil
    end
    if card.type == 2 then
        return card.due <= today and "review" or nil
    end
    return nil
end

--- Counts for the deck picker: cards that *would* be available today,
-- independent of the daily allowance (matching Anki's deck list behaviour,
-- which shows the raw due/new counts).
function Queue.counts(collection, deck_id, now, today)
    local counts = { new = 0, learning = 0, review = 0 }
    local seen_new = {}
    for _, card in ipairs(collection:cards_in_decks(
        collection:deck_subtree_ids(deck_id))) do
        local kind = classify(card, now, today)
        if kind == "new" then
            -- Sibling cards of one note both count as new in Anki's deck list,
            -- but the study queue only takes one per note at a time; counting
            -- both is what the deck list shows.
            if not seen_new[card.nid] then
                counts.new = counts.new + 1
                seen_new[card.nid] = true
            end
        elseif kind == "learning" or kind == "interday_learning" then
            counts.learning = counts.learning + 1
        elseif kind == "review" then
            counts.review = counts.review + 1
        end
    end
    return counts
end

--- Build the ordered study queue for a deck.
-- @tparam table opts { now =, today = }
function Queue.build(collection, deck_id, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local today = opts.today or collection:days_elapsed(now)
    local limits = Queue.limits(collection, deck_id, today)

    local learning, interday, reviews, new_cards = {}, {}, {}, {}
    for _, card in ipairs(collection:cards_in_decks(
        collection:deck_subtree_ids(deck_id))) do
        local kind = classify(card, now, today)
        if kind == "learning" then
            learning[#learning + 1] = card
        elseif kind == "interday_learning" then
            interday[#interday + 1] = card
        elseif kind == "review" then
            reviews[#reviews + 1] = card
        elseif kind == "new" then
            new_cards[#new_cards + 1] = card
        end
    end

    table.sort(learning, function(a, b)
        if a.due ~= b.due then
            return a.due < b.due
        end
        return a.id < b.id
    end)
    table.sort(interday, function(a, b)
        if a.due ~= b.due then
            return a.due < b.due
        end
        return a.id < b.id
    end)
    table.sort(reviews, function(a, b)
        if a.due ~= b.due then
            return a.due < b.due
        end
        return a.id < b.id
    end)
    table.sort(new_cards, function(a, b)
        if a.due ~= b.due then
            return a.due < b.due
        end
        return a.id < b.id
    end)

    local queue = {}
    for _, card in ipairs(learning) do
        queue[#queue + 1] = card
    end
    for index = 1, math.min(#interday, limits.review) do
        queue[#queue + 1] = interday[index]
    end
    for index = 1, math.min(#reviews, limits.review) do
        queue[#queue + 1] = reviews[index]
    end
    for index = 1, math.min(#new_cards, limits.new) do
        queue[#queue + 1] = new_cards[index]
    end

    return {
        cards = queue,
        counts = { new = limits.new, learning = #learning + #interday, review = limits.review },
        totals = {
            new = #new_cards,
            learning = #learning + #interday,
            review = #reviews,
        },
    }
end

--==========================================================================
-- Writing counters back
--==========================================================================

--- Apply +1 to the deck counters after an answer and persist the blob.
function Queue.bump_studied(collection, deck_id, today, field)
    local deck = collection:deck(deck_id)
    if not deck or not deck.common_blob then
        return
    end
    local common = PB.decode(deck.common_blob)
    local counters = Queue.deck_counters(collection, deck)
    if counters.last_day ~= today then
        Encode.set_varint(common, 4, 0)
        Encode.set_varint(common, 5, 0)
        Encode.set_varint(common, 3, today)
    end
    local key = field == "new" and 4 or 5
    local current = (field == "new") and counters.new_studied or counters.review_studied
    if counters.last_day ~= today then
        current = 0
    end
    Encode.set_varint(common, key, current + 1)
    Encode.set_varint(common, 3, today)

    local blob = Encode.encode(common)
    deck.common_blob = blob
    -- decks.common is declared BLOB by the schema and Anki's rslib reads it as
    -- Vec<u8>.  A plain Lua string is bound as TEXT, which writes a row that
    -- looks fine to us (our reader accepts both storage classes) but makes the
    -- collection unreadable by Anki; Conn.blob() routes it through
    -- sqlite3_bind_blob.
    collection.conn:run(
        "update decks set common = ?, mtime_secs = ?, usn = -1 where id = ?",
        Conn.blob(blob), os.time(), deck_id)
end

return Queue
