-- zstd codec tests.
--
-- On a host without libzstd these tests verify the graceful-degradation
-- contract instead of failing: `available()` must report false with a Chinese
-- reason and every codec function must return `nil, err`, never raise.

local zstd = require("sync.zstd")
local Helpers = require("helpers")

local temp_counter = 0

local function temp_path(suffix)
    temp_counter = temp_counter + 1
    local directory = os.getenv("TEMP") or os.getenv("TMP") or "."
    return string.format("%s/kindleanki_zstd_%d_%d%s", directory, os.time(),
        temp_counter, suffix or ".bin")
end

local function write_file(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function remove(path)
    pcall(os.remove, path)
end

local function fixture(name)
    return Helpers.read("tests/fixtures/" .. name)
end

-- Deterministic pseudo-random bytes; 1 MiB of them forces many output-buffer
-- turns through the streaming decoder.
local function pseudo_random(length)
    local chunks = {}
    local state = 123456789
    local produced = 0
    while produced < length do
        local bytes = {}
        for index = 1, 64 do
            state = (1103515245 * state + 12345) % 2147483648
            bytes[index] = string.char(state % 256)
        end
        chunks[#chunks + 1] = table.concat(bytes)
        produced = produced + 64
    end
    return table.concat(chunks):sub(1, length)
end

local ZSTD_MAGIC = "\40\181\47\253"

local function assert_frame(frame, label)
    assert(type(frame) == "string" and #frame > 4, label .. ": not a frame")
    assert(frame:sub(1, 4) == ZSTD_MAGIC, label .. ": bad zstd magic")
end

return {
    ["available reports a library or a Chinese reason"] = function()
        local ok, err = zstd.available()
        assert(type(ok) == "boolean", "available must return a boolean")
        if ok then
            assert(err == nil)
        else
            assert(type(err) == "string" and #err > 0,
                "a missing library needs a reason")
            assert(err:find("zstd", 1, true), err)
            -- Degraded mode: every codec entry point answers nil, message.
            for _, call in ipairs({
                function()
                    return zstd.compress("x")
                end,
                function()
                    return zstd.decompress("x")
                end,
                function()
                    return zstd.compress_file("no_such_file", temp_path())
                end,
                function()
                    return zstd.decompress_file("no_such_file", temp_path())
                end,
            }) do
                local value, reason = call()
                assert(value == nil)
                assert(type(reason) == "string" and #reason > 0)
            end
        end
    end,

    ["round-trips small payloads"] = function()
        if not zstd.available() then
            return
        end
        local payloads = {
            "",
            "x",
            '{"v":11,"k":"","c":"0.1.0-dev,kindleanki,koreader","s":"abc123"}',
            "中文 / 日本語 / 😀",
            string.rep("anki ", 1000),
            string.rep("\0\1\2\3", 1000),
        }
        for index, payload in ipairs(payloads) do
            local frame, compress_error = zstd.compress(payload)
            assert(frame, compress_error)
            assert_frame(frame, "payload " .. index)
            local decoded, decode_error = zstd.decompress(frame)
            assert(decoded == payload, decode_error)
        end
    end,

    ["round-trips 1 MiB of pseudo-random data"] = function()
        if not zstd.available() then
            return
        end
        local payload = pseudo_random(1024 * 1024)
        assert(#payload == 1024 * 1024)
        local frame, compress_error = zstd.compress(payload)
        assert(frame, compress_error)
        assert(#frame > 1024, "random data must not compress away")
        local decoded, decode_error = zstd.decompress(frame)
        assert(decoded == payload, decode_error)
    end,

    ["frames from the streaming encoder carry no content size"] = function()
        if not zstd.available() then
            return
        end
        -- AnkiWeb frames are produced by a streaming encoder: byte 5 (the
        -- Frame_Content_Size flag byte) is 0. A frame with a declared size is
        -- fine, but anki's are not, so the file path is locked to that shape.
        local path = temp_path(".txt")
        local out_path = temp_path(".zst")
        local payload = string.rep("streaming frame payload ", 4096)
        write_file(path, payload)
        local ok, err = zstd.compress_file(path, out_path)
        assert(ok, err)
        local frame = read_file(out_path)
        assert_frame(frame, "compress_file")
        assert(frame:byte(5) == 0,
            "streaming encoder must not write a frame content size")
        local decoded, decode_error = zstd.decompress(frame)
        assert(decoded == payload, decode_error)
        remove(path)
        remove(out_path)
    end,

    ["compress_file and decompress_file round-trip across chunk boundaries"] = function()
        if not zstd.available() then
            return
        end
        local path = temp_path(".txt")
        local frame_path = temp_path(".zst")
        local decoded_path = temp_path(".out")
        -- Larger than one 1 MiB default read chunk, with a small explicit
        -- chunk size to force many stream iterations on both sides.
        local payload = string.rep("0123456789abcdef", 100000)
        assert(#payload > 1024 * 1024)
        write_file(path, payload)

        local compressed, compress_error = zstd.compress_file(path, frame_path,
            4096)
        assert(compressed, compress_error)
        assert_frame(read_file(frame_path), "compress_file")

        local decompressed, decompress_error = zstd.decompress_file(frame_path,
            decoded_path, 4096)
        assert(decompressed, decompress_error)
        local output = read_file(decoded_path)
        assert(#output == #payload)
        assert(output == payload)

        remove(path)
        remove(frame_path)
        remove(decoded_path)
    end,

    ["decompress_file is unaffected by an oversized size hint"] = function()
        if not zstd.available() then
            return
        end
        local path = temp_path(".txt")
        local frame_path = temp_path(".zst")
        local decoded_path = temp_path(".out")
        -- Output larger than the 4 MiB work-buffer cap: the hint must cap the
        -- buffer, not preallocate ~100 MB or truncate the output.
        local payload = string.rep("9876543210fedcba", 300000)
        assert(#payload > zstd.MAX_OUT_BUFFER)
        write_file(path, payload)
        assert(zstd.compress_file(path, frame_path))
        local ok, err = zstd.decompress_file(frame_path, decoded_path, nil,
            100 * 1024 * 1024)
        assert(ok, err)
        assert(read_file(decoded_path) == payload)
        remove(path)
        remove(frame_path)
        remove(decoded_path)
    end,

    ["decodes captured AnkiWeb frames (no content size)"] = function()
        if not zstd.available() then
            return
        end
        local names = {
            "ankiweb_hostkey_resp",
            "ankiweb_meta_resp",
            "ankiweb_start_resp",
            "ankiweb_applychunk_req",
            "ankiweb_sanity_resp",
            "ankiweb_finish_resp",
            "ankiweb_upload_resp",
        }
        for _, name in ipairs(names) do
            local raw = fixture(name .. ".zst")
            local expected = fixture(name .. ".json")
            assert_frame(raw, name)
            assert(raw:byte(5) == 0,
                name .. ": Frame_Content_Size flag must be 0")
            local decoded, err = zstd.decompress(raw)
            assert(decoded == expected, name .. ": " .. tostring(err))
        end
    end,

    ["decompress rejects empty and truncated input"] = function()
        if not zstd.available() then
            return
        end
        local empty, empty_error = zstd.decompress("")
        assert(empty == nil)
        assert(type(empty_error) == "string" and #empty_error > 0)

        local frame = assert(zstd.compress(string.rep("hello world ", 500)))
        local truncated, truncated_error = zstd.decompress(
            frame:sub(1, #frame - 4))
        assert(truncated == nil, "a cut frame must not decode")
        assert(type(truncated_error) == "string")
        assert(truncated_error:find("截断", 1, true), truncated_error)
    end,

    ["decompress_file removes its partial output on truncation"] = function()
        if not zstd.available() then
            return
        end
        local frame_path = temp_path(".zst")
        local output_path = temp_path(".out")
        local frame = assert(zstd.compress(string.rep("hello world ", 500)))
        write_file(frame_path, frame:sub(1, #frame - 4))
        local ok, err = zstd.decompress_file(frame_path, output_path)
        assert(ok == nil, "truncated downloads must fail")
        assert(type(err) == "string" and err:find("截断", 1, true), tostring(err))
        assert(read_file(output_path) == nil,
            "the partial output file must be removed")
        remove(frame_path)
        remove(output_path)
    end,

    ["file APIs report missing paths instead of raising"] = function()
        if not zstd.available() then
            return
        end
        local ok, err = zstd.compress_file(temp_path(".missing"),
            temp_path(".zst"))
        assert(ok == nil and type(err) == "string" and err:find("读取", 1, true))

        local ok2, err2 = zstd.decompress_file(temp_path(".missing"),
            temp_path(".out"))
        assert(ok2 == nil and type(err2) == "string")
    end,
}
