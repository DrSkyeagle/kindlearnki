-- M0 diagnostics screen.
--
-- This is the only screen that exists until M1 lands the real deck list.  It
-- earns its place: it is how the first on-device run answers "which of the four
-- host capabilities is missing" without reading crash.log.
--
-- Widgets are required lazily.  Requiring `ui/widget/infomessage` pulls in
-- `ui/font`, which needs a live Screen/CanvasContext; doing that at plugin load
-- time breaks headless hosts and slows down startup for no benefit.

local _ = require("gettext")

local Probe = {}

--- @tparam table caps   result of core.capabilities.probe()
--- @tparam string version
function Probe.show(caps, version)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")

    local lines = {
        string.format("%s %s", _("Kindlearnki"), tostring(version)),
        "",
        _("运行环境："),
        tostring(caps and caps.summary or "n/a"),
    }

    if caps and caps.missing and #caps.missing > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("缺少：") .. table.concat(caps.missing, ", ")
        lines[#lines + 1] = _("请确认 KOReader ≥ v2026.07.1，且 kindlepw2 包完整解压。")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = _("（M0 骨架：复习与同步尚未接入）")

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

return Probe
