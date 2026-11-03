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
        assert(block:find("onKindlearnkiSync", 1, true),
            "同步 button bypasses the hkey check (calling run_sync directly gives a 400)")
        assert(not block:find("run_sync", 1, true),
            "同步 button calls run_sync() directly instead of onKindlearnkiSync()")
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
    ["a full download keeps the collection object alive"] = function()
        local source = Helpers.read("main.lua")
        -- Throwing the object away left the deck list and the study session
        -- holding a closed handle: the next tap died on `self.conn` being nil.
        assert(not source:find("pcall(collection.close, collection)", 1, true),
            "full_sync closes the collection that the UI still uses")
        assert(source:find("if not self.collection then", 1, true),
            "full_sync replaces the collection even when the runner reloaded it")
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

    ["the card screen is told where the media are"] = function()
        -- MuPDF resolves `<img src="paste-1234.jpg">` only when the widget is
        -- given a resource directory.  When the chain broke, every image on
        -- every card rendered as the literal `[image]` placeholder, which looks
        -- exactly like "this plugin cannot show images".
        local controller = Helpers.read("study/controller.lua")
        assert(controller:find("resource_dir = options.media_dir", 1, true),
            "the card face no longer carries a resource_dir")

        local studyview = Helpers.read("ui/studyview.lua")
        assert(studyview:find("html_resource_directory = data.resource_dir", 1, true),
            "the MuPDF widget is built without the media directory")

        local main = Helpers.read("main.lua")
        assert(main:find("media_dir = self:media_dir()", 1, true),
            "the deck screen is opened without a media directory")
    end,

    ["the study margin comes from the setting, not a constant"] = function()
        local studyview = Helpers.read("ui/studyview.lua")
        assert(studyview:find('Prefs.get("study_margin")', 1, true),
            "the study screen still uses a hardcoded margin")
        assert(not studyview:find("scaleBySize(Tokens.space.margin)", 1, true),
            "the study screen ignores the margin setting")

        local main = Helpers.read("main.lua")
        assert(main:find("prompt_study_margin", 1, true),
            "no menu entry can change the margin")
        assert(main:find("Prefs.attach(self:settings())", 1, true),
            "the preferences are never given the settings file")

        local prefs = Helpers.read("core/prefs.lua")
        assert(prefs:find("store:flush()", 1, true),
            "a changed preference is not written to disk")
    end,

    ["the card column has no invisible right margin"] = function()
        -- ScrollHtmlWidget lays the text out at `width - scroll_bar_width -
        -- text_scroll_span` and keeps the widget at `width`, so a non-zero span
        -- is blank space on the right only (0.3.5 shipped exactly that: right
        -- margin twice the left one).
        local studyview = Helpers.read("ui/studyview.lua")
        assert(not studyview:find("text_scroll_span = Screen:scaleBySize(8)", 1, true),
            "the 8-unit scroll span is back: the right margin doubles again")
    end,
}
