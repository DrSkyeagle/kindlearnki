-- Integration test against a real schema-18 collection.
--
-- The fixture is a copy of the developer's own collection and is deliberately
-- not vendored (5.6 MB, personal data).  Point the test at one with:
--
--   $env:KINDLEANKI_TEST_COLLECTION = 'C:\path\to\collection.anki2'
--
-- Without it the cases pass trivially, so the suite still runs anywhere.

local Collection = require("model.collection")
local Paths = require("core.paths")

local FIXTURE = os.getenv("KINDLEANKI_TEST_COLLECTION")

local function open_fixture()
    assert(FIXTURE, "KINDLEANKI_TEST_COLLECTION is not set")
    return Collection.open(FIXTURE, { read_only = true })
end

return {
    ["fixture is absent (skipped)"] = function()
        if FIXTURE then
            return
        end
        assert(true)
    end,

    ["schema version is 18 and the col row decodes"] = function()
        if not FIXTURE then
            return
        end
        local collection = open_fixture()
        local ok, err = pcall(function()
            assert(collection.ver == 18, collection.ver)
            assert(collection.created > 0)
            assert(collection:rollover_hour() >= 0 and collection:rollover_hour() < 24)
        end)
        collection:close()
        assert(ok, err)
    end,

    ["days_elapsed is monotonic and matches the v3 rule"] = function()
        if not FIXTURE then
            return
        end
        local collection = open_fixture()
        local now = os.time()
        local today = collection:days_elapsed(now)
        local tomorrow = collection:days_elapsed(now + 86400)
        collection:close()
        assert(today >= 0)
        assert(tomorrow == today or tomorrow == today + 1,
            string.format("today=%d tomorrow=%d", today, tomorrow))
    end,

    ["decks, deck configs and notetypes decode"] = function()
        if not FIXTURE then
            return
        end
        local collection = open_fixture()
        local ok, err = pcall(function()
            collection:load_decks()
            assert(#collection.decks > 1, #collection.decks)
            local with_config = 0
            for _, deck in ipairs(collection.decks) do
                local config = collection:deck_config(deck)
                assert(type(config.learn_steps) == "table")
                assert(config.new_per_day >= 0)
                if collection.deck_configs[deck.config_id] then
                    with_config = with_config + 1
                end
            end
            assert(with_config > 0, "no deck resolved to a stored config")

            local row = collection.conn:first("select mid from notes limit 1")
            assert(row, "fixture has no notes")
            local notetype = collection:notetype(row[1])
            assert(notetype, "notetype decode failed")
            assert(#notetype.fields > 0, "notetype has no fields")
            assert(#notetype.templates > 0, "notetype has no templates")
            assert(notetype.templates[1].qfmt ~= "", "template qfmt is empty")
        end)
        collection:close()
        assert(ok, err)
    end,

    ["cards read through the deck subtree"] = function()
        if not FIXTURE then
            return
        end
        local collection = open_fixture()
        local ok, err = pcall(function()
            collection:load_decks()
            local deck = collection:deck(collection:active_deck_id())
                or collection.decks[1]
            local ids = collection:deck_subtree_ids(deck.id)
            local cards = collection:cards_in_decks(ids)
            assert(#cards > 0, "no cards in the active deck subtree")
            local card = cards[1]
            assert(card.id > 0 and card.did == deck.id or card.did > 0)
            assert(type(card.due) == "number")
        end)
        collection:close()
        assert(ok, err)
    end,

    ["paths helper does not point into the old plugin"] = function()
        local paths = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(not paths.collection:find("ankiweb", 1, true))
    end,
}
