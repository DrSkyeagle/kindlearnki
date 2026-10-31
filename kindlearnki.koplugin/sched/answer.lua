-- Applying an answer: card row, revlog row, deck counters.
--
-- State maths live in sched/states.lua; this file only translates a
-- SchedulingStates answer into the five places v3 writes it (card columns,
-- revlog, deck counters, col.mod, and -- for a leech -- the note's tags).
-- Everything happens in one transaction, per card: a session that is killed
-- half-way must never lose an answered card.

local States = require("sched.states")
local Queue = require("sched.queue")

local Answer = {}

local RATINGS = { "again", "hard", "good", "easy" }
Answer.RATINGS = RATINGS

local DAY = 86400

--- Human text for the "next interval" hint above a rating button.
function Answer.interval_text(state)
    if not state then
        return ""
    end
    if state.kind == "review" then
        return string.format("%dd", state.scheduled_days or 1)
    end
    local secs = state.scheduled_secs or 0
    if secs >= DAY then
        return string.format("%dd", math.floor(secs / DAY + 0.5))
    elseif secs >= 3600 then
        return string.format("%dh", math.floor(secs / 3600 + 0.5))
    end
    return string.format("%dm", math.max(1, math.floor(secs / 60 + 0.5)))
end

local function revlog_kind(card, new_state)
    if new_state.kind == "review" then
        return 1
    elseif new_state.kind == "relearning" then
        return 2
    end
    return 0 -- learning / new
end

local function card_columns(card, new_state, today, now)
    local columns = {
        mod = math.floor(now * 1000),
        usn = -1,
        reps = card.reps + 1,
    }

    if new_state.kind == "review" then
        columns.type = 2
        columns.queue = 2
        columns.due = today + new_state.scheduled_days
        columns.ivl = new_state.scheduled_days
        columns.factor = math.floor((new_state.ease_factor or 2.5) * 1000 + 0.5)
        columns.left = 0
        columns.lapses = new_state.lapses or card.lapses
    elseif new_state.kind == "relearning" then
        local secs = new_state.scheduled_secs or 600
        local review = new_state.review or {}
        columns.type = 3
        columns.queue = 1
        columns.due = now + secs
        columns.ivl = review.scheduled_days or card.ivl
        columns.factor = math.floor((review.ease_factor or 2.5) * 1000 + 0.5)
        columns.left = (new_state.remaining_steps or 0) % 1000
        columns.lapses = review.lapses or card.lapses
    else
        local secs = new_state.scheduled_secs or 600
        columns.type = 1
        if secs >= DAY then
            -- Learning steps longer than a day become "day learning" in v3:
            -- due in days, steps encoded with the +1000 marker.
            columns.queue = 3
            columns.due = today + math.floor(secs / DAY + 0.5)
            columns.left = (new_state.remaining_steps or 0) + 1000
        else
            columns.queue = 1
            columns.due = now + secs
            columns.left = (new_state.remaining_steps or 0) % 1000
        end
        columns.ivl = 0
        columns.factor = card.factor
        columns.lapses = card.lapses
    end
    return columns
end

local function tag_leech(collection, note)
    if not note then
        return
    end
    local tags = " " .. (note.tags or "") .. " "
    if tags:find(" leech ", 1, true) then
        return
    end
    local updated = (note.tags or "") .. " leech "
    collection.conn:run(
        "update notes set tags = ?, mod = ?, usn = -1 where id = ?",
        updated, os.time(), note.id)
end

--- Persist one answer.
--
-- @tparam table opts { now, today, time_ms }
-- @treturn table { card = updated card row, state = new state, interval_text }
function Answer.apply(collection, card, rating, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local today = opts.today or collection:days_elapsed(now)
    local name = RATINGS[rating]
    assert(name, "rating must be 1..4, got " .. tostring(rating))

    local deck = collection:deck(card.did)
    local config = collection:deck_config(deck)
    local current = States.from_card(card, today, now)
    local answers = States.next(current, config, {})
    local new_state = answers[name]

    local note = collection:note(card.nid)
    local leeched = new_state.leeched or (new_state.review and new_state.review.leeched)

    local columns = card_columns(card, new_state, today, now)
    local revlog_id = math.floor(now * 1000)
    local last_ivl = card.ivl or 0

    collection.conn:transaction(function()
        local existing = collection.conn:first(
            "select id from revlog where id = ?", revlog_id)
        while existing do
            revlog_id = revlog_id + 1
            existing = collection.conn:first(
                "select id from revlog where id = ?", revlog_id)
        end

        collection.conn:run([[
            update cards set mod = ?, usn = -1, type = ?, queue = ?, due = ?,
                ivl = ?, factor = ?, reps = ?, lapses = ?, left = ?
            where id = ?
        ]], columns.mod, columns.type, columns.queue, columns.due,
            columns.ivl, columns.factor, columns.reps, columns.lapses,
            columns.left, card.id)

        collection.conn:run([[
            insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
            values (?, ?, -1, ?, ?, ?, ?, ?, ?)
        ]], revlog_id, card.id, rating,
            columns.type == 2 and columns.ivl or 0,
            last_ivl, columns.factor, opts.time_ms or 0,
            revlog_kind(card, new_state))

        if card.type == 0 then
            -- A new card's first answer counts toward the day's new allowance,
            -- whether it stays in learning or graduates straight away.
            Queue.bump_studied(collection, card.did, today, "new")
        elseif card.type == 2 then
            Queue.bump_studied(collection, card.did, today, "review")
        end

        collection.conn:run("update col set mod = ?", columns.mod)

        if leeched and config.leech_action == 0 then
            -- Leech action "suspend": stop showing the card.
            collection.conn:run("update cards set queue = -1 where id = ?", card.id)
            columns.queue = -1
        end
        if leeched then
            tag_leech(collection, note)
        end
    end)

    -- Reflect what the database now holds, so the UI's next "interval" hints
    -- are computed from the persisted state rather than a stale snapshot.
    local updated = collection:card_by_id(card.id) or card
    updated.queue = columns.queue

    return {
        card = updated,
        state = new_state,
        interval_text = Answer.interval_text(new_state),
        revlog_id = revlog_id,
    }
end

--- The four interval hints for the current card, for the answer buttons.
function Answer.preview(collection, card, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local today = opts.today or collection:days_elapsed(now)
    local deck = collection:deck(card.did)
    local config = collection:deck_config(deck)
    local current = States.from_card(card, today, now)
    local answers = States.next(current, config, {})
    local texts = {}
    for index, name in ipairs(RATINGS) do
        texts[index] = Answer.interval_text(answers[name])
    end
    return texts, answers
end

return Answer
