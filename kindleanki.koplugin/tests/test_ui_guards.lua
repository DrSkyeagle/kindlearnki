-- Static guards for the two UI/sync wiring bugs found on the emulated Kindle.
--
-- Both are one-line call-site mistakes that no data test would catch, so they
-- are pinned at the source level like the PagePress contract in
-- test_keybindings.lua.

local Helpers = require("helpers")

return {
    ["the deck screen's sync button goes through the login guard"] = function()
        local source = Helpers.read("main.lua")
        local block = source:match("on_sync = function%(%)(.-)end,")
        assert(block, "the deck screen on_sync callback is gone")
        assert(block:find("onKindleAnkiSync", 1, true),
            "同步 button bypasses the hkey check (calling run_sync directly gives a 400)")
        assert(not block:find("run_sync", 1, true),
            "同步 button calls run_sync() directly instead of onKindleAnkiSync()")
    end,

    ["finishing the queue leaves the card screen"] = function()
        local source = Helpers.read("study/controller.lua")
        assert(source:find("finish_round", 1, true),
            "no end-of-round path: the card screen stays on the last card")
        assert(source:find("本轮完成", 1, true),
            "no end-of-round message for the user")
        assert(source:find("Controller.close(view)", 1, true),
            "the study screen is not closed when the queue is empty")
    end,
    ["the deck list is refreshed when a session ends"] = function()
        local source = Helpers.read("study/controller.lua")
        assert(source:find("refresh_decks", 1, true),
            "the deck list keeps pre-session counts after studying")
        assert(source:find("deck_view:update(", 1, true),
            "the deck list data is never replaced")
    end,

    ["the end-of-round message uses the real UIManager"] = function()
        local source = Helpers.read("study/controller.lua")
        -- `require("ui.uimanager")` builds a second module instance with its own
        -- window stack; the message then never reaches the screen.
        assert(not source:find('load_ui("ui.uimanager")', 1, true),
            "controller loads a duplicate UIManager module")
        assert(not source:find('load_ui("ui.widget.infomessage")', 1, true),
            "controller loads a duplicate InfoMessage module")
        assert(source:find('load_ui("ui/uimanager")', 1, true),
            "the end-of-round message has no UIManager")
        assert(source:find('load_ui("ui/widget/infomessage")', 1, true),
            "the end-of-round message has no InfoMessage")
    end,
}
