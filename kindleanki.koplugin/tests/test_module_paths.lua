-- Guards for the two device-only failures reported from the Kindle:
--
--   * "登录界面不可用" -- a require of a widget that no longer exists in this
--     KOReader release (`ui/widget/centercontainer` moved under `container/`);
--   * "tapping the account field shows no keyboard, then the device restarts" --
--     a hand-built dialog with a bare InputText never gets the focus/keyboard
--     handling that KOReader's own InputDialog provides.
--
-- Neither can be exercised by the bare-LuaJIT suite, so the source is checked.

local Helpers = require("helpers")

return {
    ["login uses KOReader's InputDialog, not a hand-built text field"] = function()
        local source = Helpers.read("ui/login.lua")
        assert(source:find('require("ui/widget/inputdialog")', 1, true),
            "login no longer uses InputDialog; the keyboard path is unverified")
        assert(not source:find('require("ui/widget/inputtext")', 1, true),
            "login requires InputText directly again (device keyboard/reboot bug)")
        assert(not source:find('require("ui/widget/centercontainer")', 1, true),
            "the removed ui/widget/centercontainer path is back")
    end,

    ["the password step asks for masking"] = function()
        local source = Helpers.read("ui/login.lua")
        assert(source:find('text_type = "password"', 1, true),
            "the password dialog would echo the password on screen")
    end,

    ["the keyboard is opened when a step appears"] = function()
        local source = Helpers.read("ui/login.lua")
        assert(source:find("onShowKeyboard", 1, true),
            "the dialog no longer opens the keyboard; Voyage users would have to find the field")
    end,

    ["controller calls its own helper with the right case"] = function()
        -- A lowercase `controller.card_style()` slipped through once and made
        -- every card render fail, so tapping a deck did nothing.
        local source = Helpers.read("study/controller.lua")
        assert(not source:match("[^%w_%.]controller%.card_style"),
            "lowercase controller.card_style() is back")
        assert(source:find("Controller.card_style()", 1, true))
    end,
}
