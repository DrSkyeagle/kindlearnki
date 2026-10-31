-- Test shim for KOReader's `ffi/posix_h` module.
--
-- `lua-ljsqlite3/init.lua` requires it, reads `ffi.C.free` while building its
-- environment (so `free` must be *declared*), and uses it for BLOB binds.  This
-- plugin never binds a BLOB (text and integers only), so declaring the symbol
-- is enough on a bare Windows LuaJIT.  On the device the real KOReader module
-- is used instead — this file lives under harness/, never in the plugin.
local ffi = require("ffi")

pcall(ffi.cdef, [[void free(void *ptr);]])

return true
