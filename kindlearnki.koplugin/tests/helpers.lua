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

--- Require a module with a clean `package.loaded` entry.
--
-- `require` caches the first result for the whole process, so a case that ran
-- earlier would decide how a later case sees a module.  Testing state machines
-- (core.pagepress caches its status) needs a fresh copy per case.
function Helpers.fresh(name)
    package.loaded[name] = nil
    local ok, module = pcall(require, name)
    if not ok then
        package.loaded[name] = nil
        error(module, 2)
    end
    return module
end

return Helpers
