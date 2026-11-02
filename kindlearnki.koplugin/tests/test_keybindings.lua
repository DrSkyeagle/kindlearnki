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
        assert(source:find("group.PgFwd", 1, true), "PgFwd is not bound")
        assert(source:find("group.PgBack", 1, true), "PgBack is not bound")
        assert(source:find('event = "PageForward"', 1, true),
            "PgFwd does not emit PageForward")
        assert(source:find('event = "PageBackward"', 1, true),
            "PgBack does not emit PageBackward")
        assert(source:find("function StudyView:onPageForward", 1, true))
        assert(source:find("function StudyView:onPageBackward", 1, true))
        assert(source:find("previous_body_page", 1, true),
            "backward paging is not implemented")
    end,

    ["both screens switch the rocker on for a running framework"] = function()
        -- KOReader only enables deviced's fsr keypad in its no-framework launch
        -- mode; on top of the stock framework the bindings exist but no key
        -- event ever arrives.  Both screens have to ask for it themselves.
        for _, file in ipairs{ "ui/studyview.lua", "ui/deckview.lua" } do
            local source = Helpers.read(file)
            assert(source:find("PagePress.ensure()", 1, true),
                file .. " never enables the PagePress rocker")
            assert(not source:find("Device:hasKeys() and Device.input", 1, true),
                file .. " still gates its key bindings on hasKeys()")
        end
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
        -- be treated as "back": Voyage has no Back key, so the title-bar × is
        -- the exit.  The × comes from TitleBar's close_callback.
        local pgback_as_close = source:find(
            'PageBackward = { { group.PgBack }, event = "Close" }', 1, true)
        assert(pgback_as_close == nil, "PgBack is bound to Close")
        assert(source:find("close_callback", 1, true),
            "the title-bar close button disappeared")
        assert(source:find("TitleBar", 1, true),
            "the study screen no longer has a title bar to close from")
    end,

    ["the card body is a scroll widget, not a hand-compensated box"] = function()
        local source = Helpers.read("ui/studyview.lua")
        -- The old screen measured MuPDF's page margin from the *previous* card
        -- and shifted the body by it; fronts drifted or vanished.  A
        -- ScrollHtmlWidget owns the text area instead, so that class of bug
        -- cannot come back.
        assert(source:find("ScrollHtmlWidget", 1, true),
            "the card body is not a ScrollHtmlWidget")
        assert(not source:find("body_shift", 1, true),
            "the margin-compensation hack is back")
    end,
}

