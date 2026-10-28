-- Login dialog: email + password, with the password masked.
--
-- InputDialog does not forward `text_type` to its InputText in the KOReader
-- version this targets, so it would show the AnkiWeb password in plain text on
-- an e-ink screen.  Two InputText fields in a small frame cost about as much
-- code and behave correctly.

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputText = require("ui/widget/inputtext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = require("device").screen
local _ = require("gettext")

local Login = {}
local MT = { __index = Login }

--- @tparam table opts { on_submit = function(email, password), on_cancel = function() }
function Login:new(opts)
    local self = setmetatable(opts or {}, MT)

    self.email_input = InputText:new{
        text = self.email or "",
        hint = _("AnkiWeb 邮箱"),
        width = Screen:scaleBySize(420),
        input_type = "text",
    }
    self.password_input = InputText:new{
        hint = _("AnkiWeb 密码"),
        width = Screen:scaleBySize(420),
        text_type = "password",
        show_password_toggle = true,
    }

    local submit = Button:new{
        text = _("登录"),
        callback = function()
            self:submit()
        end,
    }
    local cancel = Button:new{
        text = _("取消"),
        callback = function()
            self:close()
            if self.on_cancel then
                self.on_cancel()
            end
        end,
    }

    self.frame = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            margin = Screen:scaleBySize(12),
            padding = Screen:scaleBySize(12),
            VerticalGroup:new{
                align = "left",
                TextBoxWidget:new{
                    text = _("登录 AnkiWeb（只保存同步密钥，不保存密码）"),
                    face = require("ui/font"):getFace("cfont", 16),
                    width = Screen:scaleBySize(420),
                },
                VerticalSpan:new{ width = Screen:scaleBySize(10) },
                self.email_input,
                VerticalSpan:new{ width = Screen:scaleBySize(8) },
                self.password_input,
                VerticalSpan:new{ width = Screen:scaleBySize(14) },
                HorizontalGroup:new{
                    submit,
                    HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                    cancel,
                },
            },
        },
    }
    return self
end

function Login:show()
    UIManager:show(self.frame)
    UIManager:setDirty(self.frame, "ui")
    return self
end

function Login:close()
    if self.frame then
        UIManager:close(self.frame)
        self.frame = nil
    end
end

function Login:submit()
    local email = (self.email_input:getText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local password = self.password_input:getText() or ""
    if email == "" or password == "" then
        return
    end
    self:close()
    if self.on_submit then
        self.on_submit(email, password)
    end
end

return Login
