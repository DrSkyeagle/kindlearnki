--[[--
zstd codec for the sync layer, bound through LuaJIT FFI.

Why not KOReader's bundled `ffi/zstd.lua`: its `zstd_uncompress()` asks
`ZSTD_getFrameContentSize()` for the output length and allocates exactly that.
AnkiWeb's frames come from a streaming encoder, so the frame header carries
Frame_Content_Size_flag = 0 / Single_Segment = 0 and there *is* no content
size (verified byte-for-byte against captured traffic: every body starts
`28 b5 2f fd 00 ...`). `ZSTD_getFrameContentSize()` then returns
ZSTD_CONTENTSIZE_UNKNOWN and the allocation fails -- or, worse, a forged
`anki-original-size` response header makes an allocation attempt sized by
remote input. So both directions drive the streaming API here:

    ZSTD_createDStream / ZSTD_initDStream / ZSTD_decompressStream
    ZSTD_createCStream / ZSTD_initCStream / ZSTD_compressStream / ZSTD_endStream

The library is found through KOReader's `ffi.loadlib` on device (it resolves
`libs/libzstd.so.1`); on the Windows test box `luajit.exe` sits next to
`tools/lj/libzstd.dll` and plain `ffi.load` finds it through the application
directory. `db/conn.lua` solves the same lookup problem for sqlite.

Failure policy: a missing library or a missing symbol never raises.
`available()` reports `false` plus a Chinese, actionable message, and every
other function returns `nil, "<reason>"`. The plugin can then show a message
instead of dying on a Kindle that has an unusual libzstd build.

@module sync.zstd
]]

local Zstd = {}

local ffi_ok, ffi = pcall(require, "ffi")

--[[-- Declared one item at a time, tolerating failures: KOReader may have
already loaded its own `ffi/zstd_h.lua` (book-info uses it), and LuaJIT raises
on a redefinition, but the existing declaration is layout-compatible. ]]
local DECLS = {
    [[size_t ZSTD_compressBound(size_t);]],
    [[unsigned ZSTD_isError(size_t);]],
    [[const char *ZSTD_getErrorName(size_t);]],
    [[typedef struct ZSTD_DStream_s ZSTD_DStream;]],
    [[ZSTD_DStream *ZSTD_createDStream(void);]],
    [[size_t ZSTD_freeDStream(ZSTD_DStream *);]],
    [[size_t ZSTD_initDStream(ZSTD_DStream *);]],
    [[size_t ZSTD_DStreamOutSize(void);]],
    -- Layout-identical to zstd.h's ZSTD_inBuffer / ZSTD_outBuffer.
    [[typedef struct { const char *src; size_t size; size_t pos; } ZSTD_inBuffer;]],
    [[typedef struct { void *dst; size_t size; size_t pos; } ZSTD_outBuffer;]],
    [[size_t ZSTD_decompressStream(ZSTD_DStream *, ZSTD_outBuffer *, ZSTD_inBuffer *);]],
    [[typedef struct ZSTD_CStream_s ZSTD_CStream;]],
    [[ZSTD_CStream *ZSTD_createCStream(void);]],
    [[size_t ZSTD_freeCStream(ZSTD_CStream *);]],
    [[size_t ZSTD_initCStream(ZSTD_CStream *, int);]],
    [[size_t ZSTD_compressStream(ZSTD_CStream *, ZSTD_outBuffer *, ZSTD_inBuffer *);]],
    [[size_t ZSTD_endStream(ZSTD_CStream *, ZSTD_outBuffer *);]],
    [[size_t ZSTD_CStreamOutSize(void);]],
}

--- Symbols we call. A libzstd that lacks any of them is not usable for sync
--- (the streaming API is the whole point; one-shot calls cannot decode the
--- content-size-less frames AnkiWeb sends).
local REQUIRED_SYMBOLS = {
    "ZSTD_isError",
    "ZSTD_getErrorName",
    "ZSTD_createDStream",
    "ZSTD_freeDStream",
    "ZSTD_initDStream",
    "ZSTD_decompressStream",
    "ZSTD_DStreamOutSize",
    "ZSTD_createCStream",
    "ZSTD_freeCStream",
    "ZSTD_initCStream",
    "ZSTD_compressStream",
    "ZSTD_endStream",
    "ZSTD_CStreamOutSize",
}

local DEFAULT_LEVEL = 3
local FALLBACK_BUFFER_SIZE = 128 * 1024
local DEFAULT_CHUNK_SIZE = 1024 * 1024
--- Upper bound for a single decompression work buffer. `anki-original-size`
--- is remote input and must never size an allocation on a 512 MB device.
local MAX_OUT_BUFFER = 4 * 1024 * 1024

local MISSING_LIBRARY = "同步功能不可用：未找到 zstd 压缩库（KOReader 自带的 "
    .. "libs/libzstd.so.1）。请确认 KOReader 安装完整且版本不低于 "
    .. "v2026.07.1，然后重启 KOReader。"
local MISSING_SYMBOLS = "同步功能不可用：当前 zstd 库缺少流式压缩接口"
    .. "（ZSTD_decompressStream 等）。请更新或重新安装 KOReader 后再试。"

local lib
local load_error
local probed = false

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

local function declare_types()
    for _, declaration in ipairs(DECLS) do
        pcall(ffi.cdef, declaration)
    end
end

local function symbol_exists(handle, symbol)
    local ok, value = pcall(function()
        return handle[symbol]
    end)
    return ok and value ~= nil
end

--- @return boolean, string|nil missing symbol name
local function usable(handle)
    for _, symbol in ipairs(REQUIRED_SYMBOLS) do
        if not symbol_exists(handle, symbol) then
            return false, symbol
        end
    end
    return true
end

local function load_candidate(candidate)
    local ok, handle = pcall(ffi.load, candidate)
    if not ok or not handle then
        return nil
    end
    return handle
end

--- Load libzstd, returning `handle` or `nil, reason`.
local function load_library()
    if not ffi_ok or type(ffi) ~= "table" then
        return nil, "同步功能不可用：当前运行环境没有 LuaJIT FFI，无法解压同步数据。"
    end
    declare_types()

    -- Remember whether *some* libzstd was loadable but lacked the streaming
    -- API: that is an update-KOReader problem, not a reinstall problem.
    local found_library = false
    local first_missing_symbol = nil

    local function try_handle(handle)
        found_library = true
        local ok, missing = usable(handle)
        if ok then
            return handle
        end
        first_missing_symbol = first_missing_symbol or missing
        return nil
    end

    -- Device path first: KOReader installs ffi.loadlib and resolves its own
    -- bundled SONAME. On Windows the test binary looks next to itself, which
    -- ffi.load does through the loader's application-directory search.
    if not is_windows() then
        if type(ffi.loadlib) ~= "function" then
            pcall(require, "ffi/loadlib")
        end
        if type(ffi.loadlib) == "function" then
            local ok, handle = pcall(ffi.loadlib, "zstd", "1")
            if ok and handle then
                local usable_handle = try_handle(handle)
                if usable_handle then
                    return usable_handle
                end
            end
        end
        for _, candidate in ipairs({ "libzstd.so.1", "libzstd.so", "libzstd", "zstd" }) do
            local handle = load_candidate(candidate)
            if handle then
                local usable_handle = try_handle(handle)
                if usable_handle then
                    return usable_handle
                end
            end
        end
    else
        for _, candidate in ipairs({ "libzstd", "libzstd.dll", "zstd" }) do
            local handle = load_candidate(candidate)
            if handle then
                local usable_handle = try_handle(handle)
                if usable_handle then
                    return usable_handle
                end
            end
        end
        if type(ffi.loadlib) == "function" then
            local ok, handle = pcall(ffi.loadlib, "zstd", "1")
            if ok and handle then
                local usable_handle = try_handle(handle)
                if usable_handle then
                    return usable_handle
                end
            end
        end
    end

    if found_library then
        return nil, MISSING_SYMBOLS .. "（缺少符号 " .. tostring(first_missing_symbol) .. "）"
    end
    return nil, MISSING_LIBRARY
end

local function ensure_library()
    if probed then
        return lib, load_error
    end
    probed = true
    lib, load_error = load_library()
    return lib, load_error
end

local function library_error()
    local _, reason = ensure_library()
    return reason or MISSING_LIBRARY
end

--- Is zstd usable on this host?
-- @treturn boolean
-- @treturn string|nil Chinese, actionable reason when false
function Zstd.available()
    local handle = ensure_library()
    if handle then
        return true
    end
    return false, library_error()
end

local function is_error(handle, code)
    return handle.ZSTD_isError(code) ~= 0
end

local function error_name(handle, code)
    local ok, name = pcall(function()
        return ffi.string(handle.ZSTD_getErrorName(code))
    end)
    if ok and name and name ~= "" then
        return name
    end
    return "unknown error"
end

local function out_buffer_size(handle, size_symbol, hint)
    local ok, size = pcall(function()
        return handle[size_symbol]()
    end)
    local result = ok and tonumber(size) or 0
    if not result or result <= 0 then
        result = FALLBACK_BUFFER_SIZE
    end
    -- A hint can make the buffer bigger, never beyond the cap; it is never
    -- used to preallocate a whole payload.
    local hint_number = tonumber(hint)
    if hint_number and hint_number > result then
        result = math.min(hint_number, MAX_OUT_BUFFER)
    end
    return result
end

--==========================================================================
-- Compression
--==========================================================================

local function compress_string(handle, data)
    local stream = ffi.gc(handle.ZSTD_createCStream(), handle.ZSTD_freeCStream)
    if stream == nil then
        error("zstd: 无法创建压缩流（内存不足？）", 0)
    end
    local code = handle.ZSTD_initCStream(stream, DEFAULT_LEVEL)
    if is_error(handle, code) then
        error("zstd 压缩初始化失败：" .. error_name(handle, code), 0)
    end

    local buffer_size = out_buffer_size(handle, "ZSTD_CStreamOutSize")
    local buffer = ffi.new("uint8_t[?]", buffer_size)
    local in_buffer = ffi.new("ZSTD_inBuffer")
    local out_buffer = ffi.new("ZSTD_outBuffer")

    local parts, part_count = {}, 0
    local function collect()
        if out_buffer.pos > 0 then
            part_count = part_count + 1
            parts[part_count] = ffi.string(buffer, tonumber(out_buffer.pos))
        end
    end

    in_buffer.src = ffi.cast("const char *", data)
    in_buffer.size = #data
    in_buffer.pos = 0
    while in_buffer.pos < in_buffer.size do
        out_buffer.dst = buffer
        out_buffer.size = buffer_size
        out_buffer.pos = 0
        code = handle.ZSTD_compressStream(stream, out_buffer, in_buffer)
        if is_error(handle, code) then
            error("zstd 压缩失败：" .. error_name(handle, code), 0)
        end
        collect()
    end

    -- Flush the frame; endStream returns 0 once everything is written.
    repeat
        out_buffer.dst = buffer
        out_buffer.size = buffer_size
        out_buffer.pos = 0
        code = handle.ZSTD_endStream(stream, out_buffer)
        if is_error(handle, code) then
            error("zstd 压缩收尾失败：" .. error_name(handle, code), 0)
        end
        collect()
    until code == 0

    if part_count == 0 then
        return ""
    end
    return table.concat(parts)
end

--- Compress a string into a single zstd frame.
-- @tparam string data
-- @treturn string|nil compressed bytes
-- @treturn string|nil Chinese error message
function Zstd.compress(data)
    if type(data) ~= "string" then
        return nil, "zstd: 待压缩数据必须是字符串，实际为 " .. type(data)
    end
    local handle = ensure_library()
    if not handle then
        return nil, library_error()
    end
    local ok, result = pcall(compress_string, handle, data)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

--==========================================================================
-- Decompression
--==========================================================================

local function decompress_string(handle, data, hint)
    local stream = ffi.gc(handle.ZSTD_createDStream(), handle.ZSTD_freeDStream)
    if stream == nil then
        error("zstd: 无法创建解压流（内存不足？）", 0)
    end
    local code = handle.ZSTD_initDStream(stream)
    if is_error(handle, code) then
        error("zstd 解压初始化失败：" .. error_name(handle, code), 0)
    end

    local buffer_size = out_buffer_size(handle, "ZSTD_DStreamOutSize", hint)
    local buffer = ffi.new("uint8_t[?]", buffer_size)
    local in_buffer = ffi.new("ZSTD_inBuffer")
    local out_buffer = ffi.new("ZSTD_outBuffer")

    in_buffer.src = ffi.cast("const char *", data)
    in_buffer.size = #data
    in_buffer.pos = 0

    local parts, part_count = {}, 0
    while true do
        out_buffer.dst = buffer
        out_buffer.size = buffer_size
        out_buffer.pos = 0
        code = handle.ZSTD_decompressStream(stream, out_buffer, in_buffer)
        if is_error(handle, code) then
            error("zstd 解压失败：" .. error_name(handle, code), 0)
        end
        local produced = tonumber(out_buffer.pos)
        if produced > 0 then
            part_count = part_count + 1
            parts[part_count] = ffi.string(buffer, produced)
        end
        if code == 0 then
            -- Whole frame decoded; AnkiWeb bodies are exactly one frame, so
            -- any trailing bytes would be a protocol error and are ignored.
            break
        end
        if in_buffer.pos >= in_buffer.size and produced == 0 then
            error("zstd 解压失败：压缩帧不完整（数据被截断）", 0)
        end
    end

    if part_count == 0 then
        return ""
    elseif part_count == 1 then
        return parts[1]
    end
    return table.concat(parts)
end

--- Decompress a complete zstd frame.
-- @tparam string data compressed bytes
-- @tparam[opt] number hint expected output size; only sizes the work buffer,
--   never allocates the whole payload, and is capped at 4 MiB
-- @treturn string|nil decompressed bytes
-- @treturn string|nil Chinese error message
function Zstd.decompress(data, hint)
    if type(data) ~= "string" then
        return nil, "zstd: 待解压数据必须是字符串，实际为 " .. type(data)
    end
    if data == "" then
        return nil, "zstd 解压失败：压缩数据为空（服务器响应不完整）"
    end
    local handle = ensure_library()
    if not handle then
        return nil, library_error()
    end
    local ok, result = pcall(decompress_string, handle, data, hint)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

--==========================================================================
-- File-to-file streaming (full sync, where the collection is too big for
-- either side to exist in memory)
--==========================================================================

local function normalize_chunk_size(value)
    local number = tonumber(value)
    if not number or number < 1 then
        return DEFAULT_CHUNK_SIZE
    end
    return math.floor(number)
end

local function compression_error(handle, stage, code)
    return string.format("zstd %s失败：%s", stage, error_name(handle, code))
end

local function compress_file_stream(handle, input, output, chunk_size)
    local stream = ffi.gc(handle.ZSTD_createCStream(), handle.ZSTD_freeCStream)
    if stream == nil then
        error("zstd: 无法创建压缩流（内存不足？）", 0)
    end
    local code = handle.ZSTD_initCStream(stream, DEFAULT_LEVEL)
    if is_error(handle, code) then
        error(compression_error(handle, "压缩初始化", code), 0)
    end

    local buffer_size = out_buffer_size(handle, "ZSTD_CStreamOutSize")
    local buffer = ffi.new("uint8_t[?]", buffer_size)
    local in_buffer = ffi.new("ZSTD_inBuffer")
    local out_buffer = ffi.new("ZSTD_outBuffer")
    local total_out = 0

    local function drain()
        local produced = tonumber(out_buffer.pos)
        if produced > 0 then
            output:write(ffi.string(buffer, produced))
            total_out = total_out + produced
        end
    end

    while true do
        local chunk = input:read(chunk_size)
        if not chunk then
            break
        end
        -- `chunk` stays alive for the whole inner loop; ffi.cast only stores
        -- the pointer, it does not keep the Lua string reachable.
        in_buffer.src = ffi.cast("const char *", chunk)
        in_buffer.size = #chunk
        in_buffer.pos = 0
        while in_buffer.pos < in_buffer.size do
            out_buffer.dst = buffer
            out_buffer.size = buffer_size
            out_buffer.pos = 0
            code = handle.ZSTD_compressStream(stream, out_buffer, in_buffer)
            if is_error(handle, code) then
                error(compression_error(handle, "压缩", code), 0)
            end
            drain()
        end
    end

    repeat
        out_buffer.dst = buffer
        out_buffer.size = buffer_size
        out_buffer.pos = 0
        code = handle.ZSTD_endStream(stream, out_buffer)
        if is_error(handle, code) then
            error(compression_error(handle, "压缩收尾", code), 0)
        end
        drain()
    until code == 0

    return total_out
end

local function decompress_file_stream(handle, input, output, chunk_size, hint)
    local stream = ffi.gc(handle.ZSTD_createDStream(), handle.ZSTD_freeDStream)
    if stream == nil then
        error("zstd: 无法创建解压流（内存不足？）", 0)
    end
    local code = handle.ZSTD_initDStream(stream)
    if is_error(handle, code) then
        error(compression_error(handle, "解压初始化", code), 0)
    end

    local buffer_size = out_buffer_size(handle, "ZSTD_DStreamOutSize", hint)
    local buffer = ffi.new("uint8_t[?]", buffer_size)
    local in_buffer = ffi.new("ZSTD_inBuffer")
    local out_buffer = ffi.new("ZSTD_outBuffer")
    local total_out = 0
    local frame_done = false

    while not frame_done do
        local chunk = input:read(chunk_size)
        if not chunk then
            -- No more input. If the frame did not finish, the download was
            -- truncated; the caller must not swap in a partial collection.
            if not frame_done then
                error("zstd 解压失败：压缩帧不完整（文件被截断）", 0)
            end
            break
        end
        in_buffer.src = ffi.cast("const char *", chunk)
        in_buffer.size = #chunk
        in_buffer.pos = 0
        while in_buffer.pos < in_buffer.size do
            out_buffer.dst = buffer
            out_buffer.size = buffer_size
            out_buffer.pos = 0
            code = handle.ZSTD_decompressStream(stream, out_buffer, in_buffer)
            if is_error(handle, code) then
                error(compression_error(handle, "解压", code), 0)
            end
            local produced = tonumber(out_buffer.pos)
            if produced > 0 then
                output:write(ffi.string(buffer, produced))
                total_out = total_out + produced
            end
            if code == 0 then
                frame_done = true
                break
            end
        end
    end

    return total_out
end

--- Compress a file into a single zstd frame, in a streaming fashion.
--
-- Reads `chunk_size` (default 1 MiB) at a time and writes the frame straight
-- to `out_path`, so a 100 MB collection never exists in memory. The frame is
-- produced by the streaming encoder and therefore carries no content size --
-- same shape as the frames AnkiWeb itself sends.
-- @tparam string in_path
-- @tparam string out_path
-- @tparam[opt] number chunk_size input block size, default 1 MiB
-- @treturn boolean|nil true on success
-- @treturn string|nil Chinese error message
function Zstd.compress_file(in_path, out_path, chunk_size)
    local handle = ensure_library()
    if not handle then
        return nil, library_error()
    end
    chunk_size = normalize_chunk_size(chunk_size)

    local input = io.open(in_path, "rb")
    if not input then
        return nil, "zstd: 无法读取文件 " .. tostring(in_path)
    end
    local output = io.open(out_path, "wb")
    if not output then
        input:close()
        return nil, "zstd: 无法写入文件 " .. tostring(out_path)
    end

    local ok, result = pcall(compress_file_stream, handle, input, output,
        chunk_size)
    input:close()
    output:close()
    if not ok then
        pcall(os.remove, out_path)
        return nil, tostring(result)
    end
    return true
end

--- Decompress a zstd frame file into `out_path`, streaming both sides.
--
-- The decompression work buffer is capped at 4 MiB. `hint` (the server's
-- `anki-original-size`) may enlarge it up to that cap but never allocates the
-- whole collection: a forged header must not be able to OOM the device.
-- @tparam string in_path
-- @tparam string out_path
-- @tparam[opt] number chunk_size input block size, default 1 MiB
-- @tparam[opt] number hint expected output size (buffer hint only)
-- @treturn boolean|nil true on success
-- @treturn string|nil Chinese error message
function Zstd.decompress_file(in_path, out_path, chunk_size, hint)
    local handle = ensure_library()
    if not handle then
        return nil, library_error()
    end
    chunk_size = normalize_chunk_size(chunk_size)

    local input = io.open(in_path, "rb")
    if not input then
        return nil, "zstd: 无法读取文件 " .. tostring(in_path)
    end
    local output = io.open(out_path, "wb")
    if not output then
        input:close()
        return nil, "zstd: 无法写入文件 " .. tostring(out_path)
    end

    local ok, result = pcall(decompress_file_stream, handle, input, output,
        chunk_size, hint)
    input:close()
    output:close()
    if not ok then
        -- A partial output file is worse than none: the caller may otherwise
        -- swap half a collection into place.
        pcall(os.remove, out_path)
        return nil, tostring(result)
    end
    return true
end

Zstd.MAX_OUT_BUFFER = MAX_OUT_BUFFER
Zstd.DEFAULT_CHUNK_SIZE = DEFAULT_CHUNK_SIZE

return Zstd
