-- Guard against KOReader globals used without being required.
--
-- KOReader does not publish UIManager / InfoMessage / etc. in `_G`; each module
-- requires what it uses.  One missing `require` in main.lua crashed every menu
-- action that showed a banner ("attempt to index global 'UIManager' (a nil
-- value)"), and no offline test could see it, because the error only happens
-- when the method runs.  The device log is what finally pinned it down.
--
-- The check is syntactic: for every plugin module, if a name is *used*
-- (`Name:` or `Name.`) it must also be declared locally (via the matching
-- require, or inside a `local` list).

local Helpers = require("helpers")

local NL = string.char(10)

local REQUIRED = {
    { name = "UIManager", module = "ui/uimanager" },
    { name = "InfoMessage", module = "ui/widget/infomessage" },
    { name = "ButtonDialog", module = "ui/widget/buttondialog" },
    { name = "InputDialog", module = "ui/widget/inputdialog" },
    { name = "ConfirmBox", module = "ui/widget/confirmbox" },
    { name = "NetworkMgr", module = "ui/network/manager" },
    { name = "DocSettings", module = "docsettings" },
    { name = "Font", module = "ui/font" },
    { name = "Blitbuffer", module = "ffi/blitbuffer" },
    { name = "Geom", module = "ui/geometry" },
    { name = "GestureRange", module = "ui/gesturerange" },
    { name = "Size", module = "ui/size" },
    { name = "Screen", module = "device" },
    { name = "Device", module = "device" },
    { name = "logger", module = "logger" },
}

-- Strip comments so a name mentioned in prose ("fits in InfoMessage.") is not
-- mistaken for a use.  Block comments are tracked across lines.
local function strip_comments(source)
    local out = {}
    local in_block = false
    local pos = 1
    while pos <= #source do
        local nl = source:find(NL, pos, true)
        local line
        if nl then
            line = source:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = source:sub(pos)
            pos = #source + 1
        end

        if in_block then
            local close = line:find("]]", 1, true)
            if close then
                in_block = false
                line = line:sub(close + 2)
            else
                line = ""
            end
        end

        local open = line:find("--[[", 1, true)
        if open then
            line = line:sub(1, open - 1)
            in_block = true
        end

        local comment = line:find("--", 1, true)
        if comment then
            line = line:sub(1, comment - 1)
        end

        out[#out + 1] = line
    end
    return table.concat(out, NL)
end

local function declares(source, name)
    return source:find("local[^" .. NL .. "]-%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

local function is_used(source, name)
    return source:find(name .. "%s*[:%.]") ~= nil
end

local SEP = string.char(92)

local function list_lua_files(root)
    local files = {}
    local command
    if package.config:sub(1, 1) == SEP then
        command = 'dir /b /s "' .. root:gsub("/", SEP) .. SEP .. '*.lua"'
    else
        command = 'find "' .. root .. '" -name "*.lua"'
    end
    local pipe = io.popen(command)
    if not pipe then
        return nil
    end
    for line in pipe:lines() do
        local path = line:gsub("%s+$", "")
        local in_tests = path:find("/tests/", 1, true)
            or path:find(SEP .. "tests" .. SEP, 1, true)
        if path:match("%.lua$") and not in_tests then
            files[#files + 1] = path
        end
    end
    pipe:close()
    return files
end

-- Scan one module body; returns a list of problems.
local function scan(path, source)
    local problems = {}
    source = strip_comments(source)
    for _, entry in ipairs(REQUIRED) do
        if is_used(source, entry.name) then
            local ok = source:find('require("' .. entry.module .. '")', 1, true)
                or declares(source, entry.name)
            if not ok then
                problems[#problems + 1] = string.format(
                    "%s uses %s without require(%q)", path, entry.name, entry.module)
            end
        end
    end
    return problems
end

return {
    ["every KOReader global is required or local"] = function()
        local files = assert(list_lua_files(Helpers.root), "cannot list files")
        assert(#files > 15, "suspiciously few files")

        local problems = {}
        for _, path in ipairs(files) do
            local handle = assert(io.open(path, "rb"))
            local source = strip_comments(handle:read("*a"))
            handle:close()

            for _, problem in ipairs(scan(path, source)) do
                problems[#problems + 1] = problem
            end
        end
        assert(#problems == 0, "missing requires:" .. NL .. "  "
            .. table.concat(problems, NL .. "  "))
    end,

    ["the guard flags a missing require and passes a correct one"] = function()
        local bad = scan("fake.lua", "UIManager:show(1)")
        assert(#bad == 1, "guard did not flag UIManager:show without a require")

        local good = scan("fake.lua",
            'local UIManager = require("ui/uimanager")' .. NL .. "UIManager:show(1)")
        assert(#good == 0, "guard rejected a correctly required module: "
            .. table.concat(good, "; "))
    end,
}
