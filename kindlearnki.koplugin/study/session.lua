-- One review session: the queue, the current card, and answering.
--
-- Deliberately unaware of the UI.  The study screen asks for `next()`, renders
-- the item, and calls `answer(rating)`; how a card looks is the renderer's
-- job, how it is scheduled is sched/'s.

local Queue = require("sched.queue")
local Answer = require("sched.answer")

local Session = {}
local MT = { __index = Session }

--- @tparam table opts { collection, deck_id, now }
function Session.new(opts)
    assert(opts and opts.collection, "collection is required")
    local self = setmetatable({
        collection = opts.collection,
        deck_id = opts.deck_id or opts.collection:active_deck_id(),
        now = opts.now or os.time(),
        done = 0,
        started_at = os.time(),
        answered = {},
    }, MT)
    self.today = self.collection:days_elapsed(self.now)
    self.queue = Queue.build(self.collection, self.deck_id, {
        now = self.now,
        today = self.today,
    })
    return self
end

function Session:remaining()
    return #self.queue.cards
end

function Session:progress()
    return { done = self.done, remaining = self:remaining() }
end

function Session:deck_name()
    local deck = self.collection:deck(self.deck_id)
    return deck and deck.name or ""
end

--- The card at the head of the queue, or nil when the session is finished.
function Session:current_card()
    return self.queue.cards[1]
end

--- Everything the study screen needs for one card.
function Session:next()
    local head = self:current_card()
    if not head then
        return nil
    end
    -- Re-read the row: a previous answer may have changed it (and the queue
    -- list holds a snapshot).
    local card = self.collection:card_by_id(head.id) or head
    self.queue.cards[1] = card

    local note = self.collection:note(card.nid)
    local notetype = note and self.collection:notetype(note.mid)
    local deck = self.collection:deck(card.did)
        or self.collection:deck(self.deck_id)

    local intervals = Answer.preview(self.collection, card, {
        now = self.now,
        today = self.today,
    })

    local template = notetype and notetype.templates[card.ord + 1]
    return {
        card = card,
        note = note,
        notetype = notetype,
        deck = deck,
        context = {
            deck_name = deck and deck.name or "",
            card_name = template and template.name or "",
        },
        intervals = intervals,
    }
end

--- Answer the card at the head of the queue.
-- @tparam number rating 1=again 2=hard 3=good 4=easy
function Session:answer(rating, opts)
    local card = self:current_card()
    if not card then
        return nil
    end
    opts = opts or {}
    opts.now = opts.now or self.now
    opts.today = opts.today or self.today
    opts.time_ms = opts.time_ms or 0

    local result = Answer.apply(self.collection, card, rating, opts)
    table.remove(self.queue.cards, 1)
    self.done = self.done + 1
    self.answered[#self.answered + 1] = { card_id = card.id, rating = rating }

    -- A card still in learning keeps its place in the session: re-insert it at
    -- its new due time, which is what makes "again -> 1 minute" actually come
    -- back rather than disappear until tomorrow.
    if result.card and result.card.type == 1 then
        local list = self.queue.cards
        local position = #list + 1
        for index = 1, #list do
            if (list[index].due or 0) > result.card.due then
                position = index
                break
            end
        end
        table.insert(list, position, result.card)
    end

    return result
end

--- Convenience for the deck list: counts for a deck.
function Session.counts(collection, deck_id, now)
    now = now or os.time()
    return Queue.counts(collection, deck_id, now, collection:days_elapsed(now))
end

return Session
