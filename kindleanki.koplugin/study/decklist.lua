-- Deck list data for the deck screen.
--
-- Pure data: no KOReader widgets, so it can be unit tested and reused from the
-- standalone shell later.  Counts include subdecks, like Anki's deck list.

local Queue = require("sched.queue")

local DeckList = {}

local function depth_of(name)
    local depth = 0
    for _ in name:gmatch("::") do
        depth = depth + 1
    end
    return depth
end

local function display_name(name)
    return name:match("([^:]+)$") or name
end

local function weekday_text(now)
    local weekdays = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }
    local fields = os.date("*t", now)
    return string.format("%d月%d日 %s", fields.month, fields.day,
        weekdays[fields.wday] or "")
end

--- Build the deck list.
-- @tparam table opts { now }
-- @treturn table { date_text, decks = {...}, total = number, total_counts = {...} }
function DeckList.build(collection, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local today = collection:days_elapsed(now)
    collection:load_decks()

    local decks = {}
    -- Anki sorts by name, which yields a preorder tree given the "::" naming.
    local sorted = {}
    for _, deck in ipairs(collection.decks) do
        sorted[#sorted + 1] = deck
    end
    table.sort(sorted, function(a, b)
        return a.name < b.name
    end)

    for _, deck in ipairs(sorted) do
        local counts = Queue.counts(collection, deck.id, now, today)
        decks[#decks + 1] = {
            id = deck.id,
            name = deck.name,
            display_name = display_name(deck.name),
            depth = depth_of(deck.name),
            counts = counts,
            total = counts.new + counts.learning + counts.review,
        }
    end

    -- "All decks" is not a real Anki deck: deck 1 is the default deck and other
    -- top-level decks are its siblings.  Sum the top-level subtrees so the
    -- footer cannot silently read 0 because deck 1 itself holds no cards.
    local total_counts = { new = 0, learning = 0, review = 0 }
    for _, deck in ipairs(sorted) do
        if not deck.parent then
            local counts = Queue.counts(collection, deck.id, now, today)
            for key in pairs(total_counts) do
                total_counts[key] = total_counts[key] + counts[key]
            end
        end
    end
    local total = total_counts.new + total_counts.learning + total_counts.review

    return {
        date_text = weekday_text(now),
        decks = decks,
        total = total,
        total_counts = total_counts,
    }
end

return DeckList
