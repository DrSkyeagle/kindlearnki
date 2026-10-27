--[[--
L1 test runner: plain LuaJIT, no KOReader required.

    luajit.exe kindleanki.koplugin/tests/run.lua [name-filter]

Each `tests/test_*.lua` returns a table of `{ ["case name"] = function() ... end }`.
A case fails by raising (assert/error); the runner catches, prints, and keeps
going so one bad case does not hide the rest.

Auto-discovery uses `dir /b` on Windows and `ls -1` elsewhere.  If neither works
the runner says so instead of silently reporting "0 passed".
]]

local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_root = tests_dir .. "/.."

package.path = table.concat({
    plugin_root .. "/?.lua",
    tests_dir .. "/?.lua",
    package.path,
}, ";")

local filter = arg and arg[1] or nil

local function list_test_files()
    local files = {}
    local is_windows = package.config:sub(1, 1) == "\\"
    local command
    if is_windows then
        command = 'dir /b "' .. (tests_dir:gsub("/", "\\")) .. '\\test_*.lua"'
    else
        command = 'ls -1 "' .. tests_dir .. '"/test_*.lua'
    end

    local pipe = io.popen(command)
    if not pipe then
        return files, "io.popen is unavailable"
    end
    for line in pipe:lines() do
        local name = line:match("([^/\\]+)$")
        if name and name:match("^test_.*%.lua$") then
            files[#files + 1] = name
        end
    end
    pipe:close()
    table.sort(files)
    return files, nil
end

local function ordered_keys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local failures = {}
local passed = 0
local skipped = 0

local files, list_error = list_test_files()
if list_error then
    io.stderr:write("cannot discover tests: " .. list_error .. "\n")
    os.exit(2)
end
if #files == 0 then
    io.stderr:write("no tests/test_*.lua found under " .. tests_dir .. "\n")
    os.exit(2)
end

for _, filename in ipairs(files) do
    local chunk, load_error = loadfile(tests_dir .. "/" .. filename)
    if not chunk then
        failures[#failures + 1] = string.format("%s: %s", filename, tostring(load_error))
    else
        local ok, cases = pcall(chunk)
        if not ok then
            failures[#failures + 1] = string.format("%s: %s", filename, tostring(cases))
        elseif type(cases) ~= "table" then
            failures[#failures + 1] = string.format("%s: did not return a table", filename)
        else
            for _, name in ipairs(ordered_keys(cases)) do
                local full_name = filename:gsub("^test_", ""):gsub("%.lua$", "") .. ": " .. name
                if filter and not full_name:find(filter, 1, true) then
                    skipped = skipped + 1
                else
                    local ok_case, err = pcall(cases[name])
                    if ok_case then
                        passed = passed + 1
                        print("ok   " .. full_name)
                    else
                        failures[#failures + 1] = full_name .. ": " .. tostring(err)
                        print("FAIL " .. full_name .. ": " .. tostring(err))
                    end
                end
            end
        end
    end
end

print("")
print(string.format("%d passed, %d failed, %d skipped", passed, #failures, skipped))
if #failures > 0 then
    print("")
    print("failures:")
    for _, failure in ipairs(failures) do
        print("  - " .. failure)
    end
end

os.exit(#failures == 0 and 0 or 1)
