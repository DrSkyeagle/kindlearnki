-- Deck list data: sub-subdecks are hidden, counts still include them.

local DeckList = require("study.decklist")

local function make_collection()
    local decks = {
        { id = 1, name = "默认" },
        { id = 2, name = "机器学习" },
        { id = 3, name = "机器学习::深度学习", parent = 2 },
        { id = 4, name = "机器学习::深度学习::CNN", parent = 3 },
        { id = 5, name = "日语" },
    }
    local by_id = {}
    for _, deck in ipairs(decks) do
        by_id[deck.id] = deck
    end
    local cards = {
        [1] = {},
        [2] = {},
        [3] = {},
        [4] = { { id = 40, nid = 40, type = 0, queue = 0, due = 0 } },
        [5] = { { id = 50, nid = 50, type = 2, queue = 2, due = 0 } },
    }

    local collection = { decks = decks, _cards = cards }
    function collection:load_decks() end
    function collection:days_elapsed() return 0 end
    function collection:deck_subtree_ids(id)
        local root = by_id[id].name
        local ids = {}
        for _, deck in ipairs(decks) do
            if deck.name == root or deck.name:sub(1, #root + 2) == root .. "::" then
                ids[#ids + 1] = deck.id
            end
        end
        return ids
    end
    function collection:cards_in_decks(ids)
        local out = {}
        for _, id in ipairs(ids) do
            for _, card in ipairs(cards[id] or {}) do
                out[#out + 1] = card
            end
        end
        return out
    end
    return collection
end

return {
    ["only the first two deck levels are shown"] = function()
        local result = DeckList.build(make_collection(), { now = 1000 })
        local names = {}
        for _, deck in ipairs(result.decks) do
            names[deck.name] = true
            assert(deck.depth < 2, "third-level deck leaked: " .. deck.name)
        end
        assert(names["默认"] and names["机器学习"] and names["日语"])
        assert(names["机器学习::深度学习"], "second level must stay visible")
        assert(not names["机器学习::深度学习::CNN"], "third level must be hidden")
    end,

    ["a hidden subdeck is still counted in its parent"] = function()
        local result = DeckList.build(make_collection(), { now = 1000 })
        for _, deck in ipairs(result.decks) do
            if deck.name == "机器学习" then
                assert(deck.counts.new == 1,
                    "parent did not inherit the hidden child's new card")
            end
        end
    end,

    ["the all-decks total still includes hidden decks"] = function()
        local result = DeckList.build(make_collection(), { now = 1000 })
        assert(result.total == 2, "expected 1 new + 1 review, got " .. result.total)
    end,
}
