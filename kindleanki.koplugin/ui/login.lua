-- Login flow: email, then password.
--
-- Uses KOReader's own `InputDialog` rather than a hand-built dialog on purpose.
-- The device report was "tapping the account field shows no keyboard, and the
-- system soft-reboots": a bare `InputText` nested inside our own containers
-- never gets the focus/keyboard handling every KOReader dialog relies on.
-- InputDialog owns that path (it is what the Wi-Fi password prompt uses on the
-- same devices), so the keyboard is its job.
--
-- `text_type = "password"` is forwarded to InputText by v2026.07
-- (inputdialog.lua:381), so the password stays masked without giving up the
-- battle-tested dialog.

local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Login = {}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function close(dialog)
    if dialog then
        pcall(UIManager.close, UIManager, dialog)
    end
end

local function cancel_button(dialog, on_cancel)
    return {
        text = _("取消"),
        id = "close",
        callback = function()
            close(dialog)
            if on_cancel then
                on_cancel()
            end
        end,
    }
end

--- Start the two-step login.
--
-- @tparam table opts { email = optional prefill, on_submit = function(email, password),
--                      on_cancel = function() }
-- @treturn table the email dialog (already shown)
function Login.start(opts)
    opts = opts or {}
    local email = trim(opts.email)

    local function ask_password()
        local dialog
        dialog = InputDialog:new{
            title = string.format("%s\n%s", _("AnkiWeb 密码"), email),
            input = "",
            input_type = "text",
            text_type = "password",
            buttons = {
                {
                    cancel_button(dialog, opts.on_cancel),
                    {
                        text = _("登录"),
                        is_enter_default = true,
                        callback = function()
                            local password = dialog:getInputText() or ""
                            close(dialog)
                            if password ~= "" and opts.on_submit then
                                opts.on_submit(email, password)
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        -- Match what a tap on the field would do: on a Voyage the keyboard
        -- should be there without the user hunting for the input box.
        pcall(dialog.onShowKeyboard, dialog)
        return dialog
    end

    local dialog
    dialog = InputDialog:new{
        title = _("AnkiWeb 邮箱"),
        input = email,
        input_type = "text",
        buttons = {
            {
                cancel_button(dialog, opts.on_cancel),
                {
                    text = _("下一步"),
                    is_enter_default = true,
                    callback = function()
                        local value = trim(dialog:getInputText())
                        close(dialog)
                        if value ~= "" then
                            email = value
                            ask_password()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    pcall(dialog.onShowKeyboard, dialog)
    return dialog
end

Login.trim = trim

return Login
