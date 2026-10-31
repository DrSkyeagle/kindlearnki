-- Syntax gate: every Lua file in the plugin must at least compile.
--
-- This exists because a broken `transport.lua` once shipped: the unit tests did
-- not require it (it needs sockets), and the packer only compared bytes.  A
-- syntax error in a module that no test loads is invisible until the user taps
-- the menu item that requires it -- which is exactly what happened on the
-- device ("网络诊断不可用: '=' expected near 'end'").
--
-- `loadfile` compiles without executing, so KOReader-only modules can be
-- checked on a bare LuaJIT.

local Helpers = require("helpers")

local function list_lua_files(root)
    local files = {}
    local is_windows = package.config:sub(1, 1) == "\\"
    local command
    if is_windows then
        command = 'dir /b /s "' .. (root:gsub("/", "\\")) .. '\\*.lua"'
    else
        command = 'find "' .. root .. '" -name "*.lua"'
    end
    local pipe = io.popen(command)
    if not pipe then
        return nil
    end
    for line in pipe:lines() do
        local path = line:gsub("\r$", "")
        if path:match("%.lua$") then
            files[#files + 1] = path
        end
    end
    pipe:close()
    return files
end

return {
    ["every plugin module compiles"] = function()
        local files = list_lua_files(Helpers.root)
        assert(files, "cannot list plugin .lua files")
        assert(#files > 20, "suspiciously few files found: " .. #files)

        local failures = {}
        for _, path in ipairs(files) do
            local chunk, err = loadfile(path)
            if not chunk then
                failures[#failures + 1] = string.format("%s: %s", path, tostring(err))
            end
        end
        assert(#failures == 0,
            "syntax error(s):\n  " .. table.concat(failures, "\n  "))
    end,
}
