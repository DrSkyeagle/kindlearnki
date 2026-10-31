-- Integration: session + renderer over a real collection.
--
-- This is the seam the unit tests cannot cover: session hands a notetype/note/
-- card to the renderer, and the renderer's output must actually contain the
-- card's text (not an empty div).  It catches exactly the "two faces are empty"
-- class of bug that a renderer unit test can miss when its fixture template is
-- simpler than reality.

local Helpers = require("helpers")
local Collection = require("model.collection")
local Session = require("study.session")
local Render = require("render.template")

local FIXTURE = os.getenv("KINDLEARNKI_TEST_COLLECTION")
local NEW_DECK = tonumber(os.getenv("KINDLEARNKI_NEW_DECK") or "1782139166456")

return {
    ["a real card renders non-empty faces"] = function()
        if not FIXTURE then
            return
        end
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            collection:load_decks()
            local cards = collection:cards_in_decks(
                collection:deck_subtree_ids(NEW_DECK))
            assert(#cards > 0, "fixture deck has no cards")
            local checked = 0
            for index = 1, math.min(8, #cards) do
                local card = cards[index]
                local note = collection:note(card.nid)
                local notetype = collection:notetype(note.mid)
                local faces = Render.card_faces(notetype, note, card, {
                    deck_name = collection:deck(card.did).name,
                    card_name = notetype.templates[card.ord + 1]
                        and notetype.templates[card.ord + 1].name or "",
                })
                assert(type(faces.question_html) == "string")
                assert(#faces.question_html > 0, "empty question for card "
                    .. tostring(card.id))
                assert(#faces.answer_html > 0, "empty answer for card "
                    .. tostring(card.id))
                -- At least one rendered face must contain one of the note's
                -- field values (stripped of markup), otherwise we rendered the
                -- wrong template or the wrong note.
                local haystack = faces.question_html .. faces.answer_html
                local found = false
                for _, field in ipairs(note.fields) do
                    local plain = field:gsub("<[^>]->", "")
                    local sample = plain:sub(1, 12)
                    if #sample >= 2 and haystack:find(sample, 1, true) then
                        found = true
                        break
                    end
                end
                assert(found, "no field content in the rendered card")
                checked = checked + 1
            end
            assert(checked > 0, "no cards rendered")
        end)
        collection:close()
        assert(ok, err)
    end,

    ["cloze answer faces reveal what question faces hide"] = function()
        if not FIXTURE then
            return
        end
        -- Cloze notetype from the fixture: find one by kind == 1.
        local collection = Collection.open(FIXTURE, { read_only = true })
        local ok, err = pcall(function()
            local row = collection.conn:first(
                "select c.id from cards c join notes n on n.id = c.nid limit 1")
            assert(row)
            local checked = false
            for _, deck in ipairs(collection.decks) do
                for _, card in ipairs(collection:cards_in_decks({ deck.id })) do
                    local note = collection:note(card.nid)
                    local notetype = note and collection:notetype(note.mid)
                    if notetype and notetype.kind == 1 then
                        local faces = Render.card_faces(notetype, note, card, {})
                        assert(faces.question_html ~= faces.answer_html,
                            "cloze question and answer are identical")
                        checked = true
                        break
                    end
                end
                if checked then
                    break
                end
            end
            -- Fixtures without a cloze notetype are fine; the renderer's own
            -- tests cover the semantics.
        end)
        collection:close()
        assert(ok, err)
    end,
}
