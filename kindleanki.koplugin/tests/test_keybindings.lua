-- Static guard for the PagePress contract.
--
-- The study screen needs a live KOReader to instantiate, so the cheapest
-- regression test for "which action do the page keys run" is to read the
-- source.  This is a real requirement, not a style rule: the cards on the
-- target decks are several screens tall, e-ink has no scrolling, and the keys
-- were explicitly asked to page the body instead of advancing the review.

local Helpers = require("helpers")

return {
    ["PagePress forwards and backwards to the body pager"] = function()
        local source = Helpers.read("ui/studyview.lua")
        assert(source:find("Input.group.PgFwd", 1, true), "PgFwd is not bound")
        assert(source:find("Input.group.PgBack", 1, true), "PgBack is not bound")
        assert(source:find('event = "PageForward"', 1, true),
            "PgFwd does not emit PageForward")
        assert(source:find('event = "PageBackward"', 1, true),
            "PgBack does not emit PageBackward")
        assert(source:find("function StudyView:onPageForward", 1, true))
        assert(source:find("function StudyView:onPageBackward", 1, true))
        assert(source:find("previous_body_page", 1, true),
            "backward paging is not implemented")
    end,

    ["the review flow is no longer bound to the page keys"] = function()
        local source = Helpers.read("ui/studyview.lua")
        assert(not source:find("ADVANCE_RATING", 1, true),
            "the old advance-to-answer rating binding is back")
        assert(not source:find("event = \"Advance\"", 1, true),
            "a page key still emits Advance")
    end,

    ["exiting does not rely on a key the Voyage lacks"] = function()
        local source = Helpers.read("ui/studyview.lua")
        -- Back is bound (harmless on devices that have it), but PgBack must not
        -- be treated as "back": Voyage has no Back key and the × hot zone is the
        -- documented exit.
        local pgback_as_close = source:find(
            'PageBackward = { { Input.group.PgBack }, event = "Close" }', 1, true)
        assert(pgback_as_close == nil, "PgBack is bound to Close")
        assert(source:find("exit_hit", 1, true) or source:find("Tokens.size.exit", 1, true),
            "the touch exit hot zone disappeared")
    end,
}

