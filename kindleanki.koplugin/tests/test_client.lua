-- Client tests: the real client code against a scripted transport.
--
-- The fake records every request, so the suite can assert the wire shape
-- (URL, headers, zstd body), the decoding of real captured response frames,
-- redirect handling and the Chinese error mapping -- all without a network.

local Helpers = require("helpers")
local json = require("sync.json")
local zstd = require("sync.zstd")
local protocol = require("sync.protocol")
local Client = require("sync.client")

local ENDPOINT = "https://sync.ankiweb.net/"
local ZSTD_MAGIC = "\40\181\47\253"

local ZSTD_OK = zstd.available()

local function fixture(name)
    return Helpers.read("tests/fixtures/" .. name)
end

--- A transport whose responses are scripted in order.
local function scripted(responses)
    local transport = { calls = {}, index = 0 }
    function transport.request(request)
        transport.index = transport.index + 1
        transport.calls[#transport.calls + 1] = request
        local response = responses[transport.index]
        assert(response, string.format(
            "unexpected request #%d: %s", transport.index,
            tostring(request.url)))
        if response.transport_error then
            return nil, response.transport_error
        end
        return {
            status = response.status or 200,
            headers = response.headers or {},
            body = response.body or "",
        }
    end
    return transport
end

local function request_at(transport, index)
    return transport.calls[index or #transport.calls]
end

local function header_of(transport, index)
    local request = request_at(transport, index)
    local encoded = request.headers["anki-sync"]
    assert(type(encoded) == "string", "missing anki-sync header")
    return json.decode(encoded)
end

local function body_of(transport, index)
    local request = request_at(transport, index)
    local text, err = zstd.decompress(request.body)
    assert(text, err)
    return json.decode(text)
end

--- Assert the invariants every collection-sync request must satisfy.
local function assert_request(transport, index, method, url)
    local request = request_at(transport, index)
    assert(request.method == "POST", "sync endpoints are POST only")
    assert(request.url == (url or (ENDPOINT .. "sync/" .. method)),
        "unexpected url: " .. tostring(request.url))
    assert(request.headers["content-type"] == "application/octet-stream")
    local header = header_of(transport, index)
    assert(header.v == 11, "sync version must be 11")
    assert(type(header.k) == "string", "k key must be present")
    assert(type(header.c) == "string" and header.c ~= "", "c key must be present")
    assert(type(header.s) == "string" and #header.s == 6,
        "s key must be a 6-character session key")
    assert(header.s:match("^%w+$"), "session key must be alphanumeric")
    assert(request.body:sub(1, 4) == ZSTD_MAGIC,
        "request bodies must be zstd frames")
    return header
end

local function zstdframe(text)
    local frame, err = zstd.compress(text)
    assert(frame, err)
    return frame
end

local function jsonframe(value)
    return zstdframe(json.encode(value))
end

return {
    ["new normalizes the endpoint"] = function()
        local client = Client.new{ transport = scripted({}) }
        assert(client.endpoint == ENDPOINT, client.endpoint)
        assert(client.hkey == "")

        local no_slash = Client.new{
            endpoint = "https://sync.ankiweb.net",
            transport = scripted({}),
        }
        assert(no_slash.endpoint == ENDPOINT)

        local with_path = Client.new{
            endpoint = "https://example.test/base",
            transport = scripted({}),
        }
        assert(with_path.endpoint == "https://example.test/base/")
        assert(with_path:url_for("meta")
            == "https://example.test/base/sync/meta")
    end,

    ["session keys are six alphanumeric characters"] = function()
        local first = Client.new_session_key()
        local second = Client.new_session_key()
        for _, key in ipairs({ first, second }) do
            assert(#key == 6, key)
            assert(key:match("^%w+$"), key)
        end
    end,

    ["meta sends zstd JSON and decodes a captured response"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local meta, err = client:meta()
        assert(meta, err)
        assert(meta.mod == 1790701394975, meta.mod)
        assert(meta.scm == 1790701394676)
        assert(meta.usn == 2)
        assert(meta.cont == true)
        assert(meta.msg == "")

        local header = assert_request(transport, 1, "meta")
        assert(header.k == "", "no host key before login")
        assert(header.c == protocol.CLIENT_ID)
        local body = body_of(transport, 1)
        assert(body.v == 11)
        assert(body.cv == protocol.CLIENT_VERSION)
        assert(#transport.calls == 1)
    end,

    ["host_key sends an empty k and stores the returned key"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_hostkey_resp.zst") },
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{
            transport = transport,
            hkey = "stale-key",
        }
        local key, err = client:host_key("user@example.com", "secret")
        assert(key, err)
        assert(key == "e242db09b2d1cad62c7cd4246836ccb84c510c3b", key)

        local login_header = assert_request(transport, 1, "hostKey")
        assert(login_header.k == "", "hostKey must send an empty host key")
        local login_body = body_of(transport, 1)
        assert(login_body.u == "user@example.com")
        assert(login_body.p == "secret")

        -- The key is now used on every later request, and the session key is
        -- stable for the whole sync session.
        local meta, meta_err = client:meta()
        assert(meta, meta_err)
        local meta_header = assert_request(transport, 2, "meta")
        assert(meta_header.k == key)
        assert(meta_header.s == login_header.s,
            "the session key must stay the same for the session")
    end,

    ["start sends minUsn/lnewer and normalizes missing graves"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_start_resp.zst") },
            { body = jsonframe({ cards = { 11 }, decks = {} }) },
        })
        local client = Client.new{ transport = transport }

        local graves, err = client:start(7, true)
        assert(graves, err)
        assert(#graves.cards == 0 and #graves.notes == 0 and #graves.decks == 0)
        local body = body_of(transport, 1)
        assert(body.minUsn == 7)
        assert(body.lnewer == true)
        assert(body.graves == nil, "deprecated graves field is omitted")
        assert_request(transport, 1, "start")

        local second, second_err = client:start(0, false)
        assert(second, second_err)
        assert(second.cards[1] == 11)
        assert(#second.notes == 0, "missing lists become empty tables")
        assert(body_of(transport, 2).lnewer == false)
    end,

    ["apply_changes sends the required deck tuple"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = jsonframe({
                models = json.array(),
                decks = json.array({ json.array(), json.array() }),
                tags = json.array(),
            }) },
        })
        local client = Client.new{ transport = transport }
        local changes, err = client:apply_changes()
        assert(changes, err)
        assert(#changes.models == 0 and #changes.tags == 0)
        assert(#changes.decks == 2, "decks must be a 2-tuple")

        local body = body_of(transport, 1)
        assert(#body.changes.decks == 2)
        assert(body.changes.decks[1] ~= nil and body.changes.decks[2] ~= nil)
        assert_request(transport, 1, "applyChanges")
    end,

    ["chunk posts an empty object and returns the chunk"] = function()
        if not ZSTD_OK then
            return
        end
        local row = protocol.card_row({
            id = 1, nid = 2, did = 3, mod = 4, usn = 5, due = 6, data = "{}",
        })
        local transport = scripted({
            { body = jsonframe({ done = false, cards = { row } }) },
            { body = jsonframe({ done = true }) },
        })
        local client = Client.new{ transport = transport }
        local chunk, err = client:chunk()
        assert(chunk, err)
        assert(chunk.done == false)
        assert(#chunk.cards == 1)
        assert(#chunk.cards[1] == 18)
        assert(body_of(transport, 1).done == nil, "EmptyInput is just {}")

        local last, last_err = client:chunk()
        assert(last, last_err)
        assert(last.done == true)
        assert(last.cards == nil)
        assert_request(transport, 1, "chunk")
        assert_request(transport, 2, "chunk")
    end,

    ["apply_chunk wraps rows, omits empty lists and ignores the empty reply"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            -- AnkiWeb answers applyChunk with a JSON null.
            { body = zstdframe("null") },
        })
        local client = Client.new{ transport = transport }
        local ok, err = client:apply_chunk({
            done = true,
            cards = { protocol.card_row({ id = 1, nid = 2, data = "{}" }) },
            notes = {},
            revlog = {},
        })
        assert(ok, err)

        local body = body_of(transport, 1)
        assert(body.chunk.done == true)
        assert(#body.chunk.cards == 1)
        assert(#body.chunk.cards[1] == 18)
        assert(body.chunk.notes == nil, "empty lists are omitted")
        assert(body.chunk.revlog == nil)
        assert_request(transport, 1, "applyChunk")
    end,

    ["sanity_check2 sends positional counts and returns status"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_sanity_resp.zst") },
            { body = jsonframe({ status = "bad", c = json.array(), s = json.array() }) },
        })
        local client = Client.new{ transport = transport }
        local payload = protocol.sanity_counts(1, 1, 0, 0, {
            notetypes = 6,
            decks = 1,
            deck_config = 1,
        })
        local status, err = client:sanity_check2(payload)
        assert(status == "ok", err)
        local body = body_of(transport, 1)
        assert(json.encode(body.client) == "[[0,0,0],1,1,0,0,6,1,1]")
        assert_request(transport, 1, "sanityCheck2")

        -- A named payload is accepted too.
        local second, second_err, response = client:sanity_check2({
            cards = 2,
            notes = 2,
            revlog = 0,
            graves = 0,
            notetypes = 1,
            decks = 1,
            deck_config = 1,
        })
        assert(second == "bad", second_err)
        assert(response.status == "bad")
    end,

    ["finish returns the bare number from the captured response"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_finish_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local modified, err = client:finish()
        assert(modified == 1790701395200, err)
        assert_request(transport, 1, "finish")
        assert(#body_of(transport, 1) == 0, "finish sends an empty object")
    end,

    ["upload compresses the raw database and accepts OK"] = function()
        if not ZSTD_OK then
            return
        end
        local database = "SQLite format 3\0" .. string.rep("\0\1", 2048)
        local transport = scripted({
            { body = fixture("ankiweb_upload_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local ok, err = client:upload(database)
        assert(ok, err)
        local request = request_at(transport, 1)
        assert(request.url == ENDPOINT .. "sync/upload")
        local sent, decompress_error = zstd.decompress(request.body)
        assert(sent == database, decompress_error)
        assert_request(transport, 1, "upload")
    end,

    ["upload accepts an already-compressed frame"] = function()
        if not ZSTD_OK then
            return
        end
        -- The streaming full-upload path hands the client a frame it built
        -- with zstd.compress_file(); it must not be compressed a second time.
        local database = "SQLite format 3\0" .. string.rep("B", 1024)
        local frame = assert(zstd.compress(database))
        local transport = scripted({
            { body = fixture("ankiweb_upload_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        assert(client:upload(frame))
        assert(request_at(transport, 1).body == frame,
            "an existing zstd frame is sent verbatim")
        assert(zstd.decompress(request_at(transport, 1).body) == database)
    end,

    ["upload surfaces the server rejection text"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = zstdframe("Upload too large; please sync with desktop") },
        })
        local client = Client.new{ transport = transport }
        local ok, err = client:upload("SQLite format 3\0")
        assert(ok == nil)
        assert(type(err) == "string" and err:find("上传失败", 1, true), err)
        assert(err:find("Upload too large", 1, true), err)
    end,

    ["download returns the decompressed sqlite bytes"] = function()
        if not ZSTD_OK then
            return
        end
        local database = "SQLite format 3\0" .. string.rep("A", 4096)
        local transport = scripted({
            { body = zstdframe(database) },
        })
        local client = Client.new{ transport = transport }
        local bytes, err = client:download()
        assert(bytes == database, err)
        assert_request(transport, 1, "download")
        assert(json.encode(body_of(transport, 1)) == "{}")
    end,

    ["abort succeeds on the empty reply and reports failures"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = zstdframe("null") },
            { status = 500, body = "boom" },
        })
        local client = Client.new{ transport = transport }
        assert(client:abort() == true)
        local ok, err = client:abort()
        assert(ok == nil)
        assert(type(err) == "string" and err:find("HTTP 500", 1, true), err)
    end,

    ["follows the per-user 308 and keeps the new host"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            {
                status = 308,
                headers = { location = "https://sync10.ankiweb.net/" },
            },
            { body = fixture("ankiweb_meta_resp.zst") },
            { body = jsonframe({ done = true }) },
        })
        local client = Client.new{ transport = transport }
        local meta, err = client:meta()
        assert(meta, err)
        assert(client.endpoint == "https://sync10.ankiweb.net/",
            client.endpoint)
        assert(request_at(transport, 2).url
            == "https://sync10.ankiweb.net/sync/meta")

        -- Later requests of the session go straight to the assigned host.
        local chunk, chunk_err = client:chunk()
        assert(chunk, chunk_err)
        assert(request_at(transport, 3).url
            == "https://sync10.ankiweb.net/sync/chunk")
    end,

    ["resolves a path-relative Location without replacing the endpoint"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { status = 308, headers = { Location = "/sync2/meta" } },
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local meta, err = client:meta()
        assert(meta, err)
        assert(request_at(transport, 2).url
            == "https://sync.ankiweb.net/sync2/meta")
        assert(client.endpoint == ENDPOINT, client.endpoint)
    end,

    ["rejects a 308 without Location and gives up after three"] = function()
        if not ZSTD_OK then
            return
        end
        local no_location = Client.new{
            transport = scripted({ { status = 308 } }),
        }
        local meta, err = no_location:meta()
        assert(meta == nil)
        assert(type(err) == "string" and err:find("同步主机", 1, true), err)

        local loop_responses = {}
        for index = 1, 4 do
            loop_responses[index] = {
                status = 308,
                headers = { location = "https://sync" .. index .. ".test/" },
            }
        end
        local looping = Client.new{ transport = scripted(loop_responses) }
        local looped_meta, loop_err = looping:meta()
        assert(looped_meta == nil)
        assert(type(loop_err) == "string"
            and loop_err:find("重定向", 1, true), loop_err)
    end,

    ["maps HTTP errors to actionable Chinese messages"] = function()
        local cases = {
            { 400, "客户端版本" },
            { 401, "登录状态" },
            { 403, "邮箱和密码" },
            { 409, "另一台设备" },
            { 500, "服务器内部错误" },
        }
        for _, case in ipairs(cases) do
            local transport = scripted({
                { status = case[1], body = "server says no" },
            })
            local client = Client.new{ transport = transport }
            local meta, err = client:meta()
            assert(meta == nil, "HTTP " .. case[1] .. " must not parse")
            assert(type(err) == "string", "err must be a string")
            assert(err:find("HTTP " .. case[1], 1, true), err)
            assert(err:find(case[2], 1, true), err)
            assert(err:find("server says no", 1, true), err)
        end
    end,

    ["maps transport failures to actionable Chinese messages"] = function()
        local cases = {
            { "timeout after 30s", "超时" },
            { "connection refused", "无法连接" },
            { "connection reset by peer", "无法连接" },
            { "unexpected weirdness", "网络请求失败" },
        }
        for _, case in ipairs(cases) do
            local client = Client.new{
                transport = scripted({ { transport_error = case[1] } }),
            }
            local meta, err = client:meta()
            assert(meta == nil)
            assert(type(err) == "string")
            assert(err:find(case[2], 1, true), case[1] .. " -> " .. err)
        end
    end,

    ["a malformed JSON response is reported, not raised"] = function()
        if not ZSTD_OK then
            return
        end
        local client = Client.new{
            transport = scripted({ { body = zstdframe("not json") } }),
        }
        local meta, err = client:meta()
        assert(meta == nil)
        assert(type(err) == "string" and err:find("格式错误", 1, true), err)
    end,

    ["client_version feeds both cv and the c header"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{
            transport = transport,
            client_version = "9.9.9",
        }
        assert(client:meta())
        local header = header_of(transport, 1)
        assert(header.c == "9.9.9,kindleanki,koreader", header.c)
        assert(body_of(transport, 1).cv == "anki,9.9.9 (kindleanki),koreader")
    end,

    ["drives the full incremental conversation in order"] = function()
        if not ZSTD_OK then
            return
        end
        -- Mirrors the sequence sync/runner.lua drives: meta, start,
        -- applyChanges, pull, push, sanity, finish.
        local transport = scripted({
            { body = fixture("ankiweb_meta_resp.zst") },
            { body = fixture("ankiweb_start_resp.zst") },
            { body = jsonframe({
                models = json.array(),
                decks = json.array({ json.array(), json.array() }),
                tags = json.array(),
            }) },
            { body = jsonframe({ done = true }) },
            { body = zstdframe("null") },
            { body = fixture("ankiweb_sanity_resp.zst") },
            { body = fixture("ankiweb_finish_resp.zst") },
        })
        local client = Client.new{ transport = transport, hkey = "h" }

        assert(client:meta())
        assert(client:start(0, true))
        assert(client:apply_changes())
        local chunk = assert(client:chunk())
        assert(chunk.done == true)
        assert(client:apply_chunk({
            done = true,
            cards = { protocol.card_row({ id = 1, nid = 2, data = "{}" }) },
        }))
        local status = client:sanity_check2(protocol.sanity_counts(1, 1, 0, 0, {
            notetypes = 6,
            decks = 1,
            deck_config = 1,
        }))
        assert(status == "ok")
        assert(client:finish() == 1790701395200)

        assert(#transport.calls == 7)
        local expected = {
            "meta", "start", "applyChanges", "chunk", "applyChunk",
            "sanityCheck2", "finish",
        }
        for index, method in ipairs(expected) do
            assert_request(transport, index, method)
        end
    end,

    ["a missing zstd library is reported before any request is sent"] = function()
        local saved_zstd = package.loaded["sync.zstd"]
        local saved_client = package.loaded["sync.client"]
        package.loaded["sync.zstd"] = {
            available = function()
                return false, "同步功能不可用：未找到 zstd 压缩库。"
            end,
            compress = function()
                return nil, "同步功能不可用：未找到 zstd 压缩库。"
            end,
            decompress = function()
                return nil, "同步功能不可用：未找到 zstd 压缩库。"
            end,
        }
        package.loaded["sync.client"] = nil

        local ok, result = pcall(function()
            local StubClient = require("sync.client")
            local transport = scripted({})
            local client = StubClient.new{ transport = transport }
            local meta, err = client:meta()
            assert(meta == nil)
            assert(type(err) == "string")
            assert(err:find("zstd", 1, true), err)
            assert(#transport.calls == 0,
                "compression must fail before any bytes are sent")
        end)

        package.loaded["sync.zstd"] = saved_zstd
        package.loaded["sync.client"] = saved_client
        assert(ok, result)
    end,

    ["follows a 303 See Other to the assigned sync host"] = function()
        -- AnkiWeb answers with 303, not 308: this is the exact response the
        -- device log showed for /sync/download before the fix.
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            {
                status = 303,
                headers = { location = "https://sync5.ankiweb.net/" },
                body = "{}",
            },
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local meta, err = client:meta()
        assert(meta, err)
        assert(client.endpoint == "https://sync5.ankiweb.net/", client.endpoint)
        assert(request_at(transport, 2).url
            == "https://sync5.ankiweb.net/sync/meta")
    end,

    ["a 303 that points at a full route keeps the method URL"] = function()
        if not ZSTD_OK then
            return
        end
        local transport = scripted({
            { status = 303, headers = { location = "https://sync5.ankiweb.net/sync/meta" } },
            { body = fixture("ankiweb_meta_resp.zst") },
        })
        local client = Client.new{ transport = transport }
        local meta, err = client:meta()
        assert(meta, err)
        assert(request_at(transport, 2).url
            == "https://sync5.ankiweb.net/sync/meta")
    end,

    ["a 303 without Location is reported as such"] = function()
        if not ZSTD_OK then
            return
        end
        local client = Client.new{ transport = scripted({ { status = 303 } }) }
        local meta, err = client:meta()
        assert(meta == nil)
        assert(type(err) == "string" and err:find("303", 1, true), err)
        assert(err:find("同步主机", 1, true), err)
    end,

    ["resolve_host follows the 308 so a first download hits the right host"] = function()
        if not ZSTD_OK then
            return
        end
        local payload = zstd.compress("SQLite format 3 " .. string.rep("x", 64))
        local transport = scripted({
            -- /sync/meta on the default host
            { status = 308, headers = { location = "https://sync10.ankiweb.net/" } },
            -- /sync/meta on the assigned host
            { body = fixture("ankiweb_meta_resp.zst") },
            -- /sync/download on the assigned host
            { body = payload },
        })
        local client = Client.new{ transport = transport }
        local ok, err = client:resolve_host()
        assert(ok, err)
        assert(client.endpoint == "https://sync10.ankiweb.net/", client.endpoint)
        assert(request_at(transport, 2).url
            == "https://sync10.ankiweb.net/sync/meta")

        local bytes, download_err = client:download()
        assert(bytes, download_err)
        assert(bytes:sub(1, 15) == "SQLite format 3", bytes:sub(1, 15))
        assert(request_at(transport, 3).url
            == "https://sync10.ankiweb.net/sync/download")
    end,

    ["resolve_host reports a failed meta instead of downloading anyway"] = function()
        if not ZSTD_OK then
            return
        end
        local client = Client.new{
            transport = scripted({ { status = 403, body = "nope" } }),
        }
        local ok, err = client:resolve_host()
        assert(ok == nil)
        assert(type(err) == "string" and err:find("403", 1, true), err)
    end,
}
