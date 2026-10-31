-- Small helpers shared by the test files.
--
-- Nothing here may depend on KOReader: the whole point of the L1 layer is that
-- `luajit.exe tests/run.lua` works on a bare Windows box.

local Helpers = {}

local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = source:match("^(.*)[/\\][^/\\]*$") or "."
Helpers.root = tests_dir .. "/.."

--- Read a file relative to the plugin root.
function Helpers.read(relative)
    local path = Helpers.root .. "/" .. relative
    local file = assert(io.open(path, "rb"), "cannot open " .. path)
    local data = file:read("*a")
    file:close()
    return data
end

--- Does the file contain `needle` verbatim?
function Helpers.contains(relative, needle)
    return Helpers.read(relative):find(needle, 1, true) ~= nil
end

return Helpers
