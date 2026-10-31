--[[--
Wire-level AnkiWeb sync client: framing, headers, endpoints, error mapping.

This module knows nothing about sqlite or sync bookkeeping. It turns Lua tables
into zstd-wrapped JSON requests, decodes the responses, and maps every failure
onto a Chinese, actionable message. A later milestone (`sync/normal.lua`,
`sync/full.lua`) drives the actual sync sequence on top of it.

Transport is injected, never constructed here:

    transport.request{ url=, method="POST", headers={...}, body=string }
        -> { status=number, headers=table, body=string }

That is the only way this layer stays testable on a bare Windows LuaJIT (the
L1 suite drives the real client code against a scripted fake), and it keeps the
one KOReader-specific dependency -- LuaSocket/LuaSec and the CA bundle -- in a
thin adapter that is written once the transport contract is settled.

Wire rules owned by this module (evidence in doc/SYNC-SPEC.md §1):

  * every request is a POST under `<endpoint>sync/<method>`;
  * the `anki-sync` header always has all four keys `v/k/c/s` -- AnkiWeb
    answers a bare 400 when one is missing -- and `v` is 11;
  * `s` is a fresh six-character session key per client, echoed by the server
    as an "active sync" lock; it must stay the same for the whole session;
  * request and response bodies are zstd frames; `upload`/`finish`/`download`
    carry non-JSON payloads after decompression (text, bare number, sqlite
    bytes);
  * a 308 redirect is followed (AnkiWeb assigns a per-user host through the
    `Location` header on `sync/meta`) at most three times.

Retry policy: the client itself never replays a request after a network
failure. Only a 308 is re-POSTed, and that is not a retry -- the server has
explicitly told us it did not process the request and named where to send it.
Replaying after an ambiguous failure ("connection reset") risks applying the
same chunk twice, and the protocol's usn accounting has no idempotency key to
make that safe.

@module sync.client
]]

local json = require("sync.json")
local protocol = require("sync.protocol")
local zstd = require("sync.zstd")

local Client = {}
Client.__index = Client

Client.MAX_REDIRECTS = protocol.MAX_REDIRECTS

-- AnkiWeb answers the first request for a user with a redirect to the sync
-- host assigned to that account.  It uses 303 (See Other); proxies use 307/308,
-- and some middleboxes emit 301/302.  All of them mean "repeat this request
-- against Location", which is what rslib does for the same response.
local REDIRECT_STATUS = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

local SESSION_ALPHABET =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local SESSION_LENGTH = 6

--- Every zstd frame starts with the same four bytes; used only to recognise
--- an already-compressed upload body.
local ZSTD_MAGIC = "\40\181\47\253"

local session_counter = 0

--[[-- A fresh six-character session key. Anki generates it client-side; the
server only uses it to detect two devices syncing at once, so it has to be
unlikely to collide, not cryptographically random. `math.random` is mixed with
the clock and a process-local counter without reseeding the global PRNG (which
KOReader shares with the rest of the UI). ]]
local function new_session_key()
    session_counter = session_counter + 1
    local entropy = table.concat({
        tostring(os.time()),
        string.format("%d", math.floor(os.clock() * 1000000)),
        tostring(session_counter),
        tostring(math.random(1, 2147483647)),
    }, ":")

    local hash = 5381
    for index = 1, #entropy do
        hash = (hash * 33 + entropy:byte(index)) % 2147483647
    end

    local out = {}
    for index = 1, SESSION_LENGTH do
        hash = (hash * 1103515245 + 12345) % 2147483648
        local position = hash % #SESSION_ALPHABET + 1
        out[index] = SESSION_ALPHABET:sub(position, position)
    end
    return table.concat(out)
end

Client.new_session_key = new_session_key

local function normalize_endpoint(endpoint)
    local text = (tostring(endpoint or protocol.ENDPOINT_DEFAULT))
        :gsub("/+$", "")
    if text == "" then
        text = (protocol.ENDPOINT_DEFAULT):gsub("/+$", "")
    end
    return text .. "/"
end

local function header_value(headers, wanted)
    if type(headers) ~= "table" then
        return nil
    end
    local direct = headers[wanted] or headers[wanted:lower()]
        or headers[wanted:upper()]
    if direct ~= nil then
        return direct
    end
    for name, value in pairs(headers) do
        if type(name) == "string" and name:lower() == wanted:lower() then
            return value
        end
    end
    return nil
end

local function body_snippet(body)
    if type(body) ~= "string" or body == "" then
        return ""
    end
    -- Error pages are plain text; keep the message one line and short so it
    -- fits in KOReader's InfoMessage.
    local text = body:gsub("[%z\1-\31]", " "):gsub("%s+", " ")
    if #text > 160 then
        text = text:sub(1, 160) .. "..."
    end
    return "（服务器返回：" .. text .. "）"
end

--- Map a transport-level failure onto a Chinese, actionable message.
--
-- The transport contract has a single error string, so the mapping is
-- best-effort: the point is that the user sees "check Wi-Fi" or "check the
-- clock" instead of a LuaSocket stack trace.
local function network_error(reason)
    local text = tostring(reason or ""):lower()
    if text:find("timeout", 1, true) or text:find("timed out", 1, true)
        or text:find("超时", 1, true) then
        return "同步超时：请检查 Wi-Fi 信号后重试。"
            .. "（" .. tostring(reason) .. "）"
    elseif text:find("resolve", 1, true) or text:find("network", 1, true)
        or text:find("connect", 1, true) or text:find("unreachable", 1, true)
        or text:find("refused", 1, true) or text:find("dns", 1, true)
        or text:find("tls", 1, true) or text:find("ssl", 1, true) then
        return "无法连接 AnkiWeb：请检查 Wi-Fi 连接、系统时间和网络代理后重试。"
            .. "（" .. tostring(reason) .. "）"
    end
    return "网络请求失败：请检查网络连接后重试。"
        .. "（" .. tostring(reason) .. "）"
end

--- Map an HTTP error status onto a Chinese, actionable message.
local function status_error(status, body)
    local detail = body_snippet(body)
    if status == 400 then
        return "请求被服务器拒绝（HTTP 400）：客户端版本可能过旧，或同步数据"
            .. "格式不正确。请更新插件后重试。" .. detail
    elseif status == 401 then
        return "登录状态已失效（HTTP 401）：请重新输入 AnkiWeb 邮箱和密码"
            .. "后重试。" .. detail
    elseif status == 403 then
        return "AnkiWeb 拒绝访问（HTTP 403）：请检查邮箱和密码是否正确；"
            .. "若密码刚改过，请重新登录。" .. detail
    elseif status == 404 then
        return "同步接口不存在（HTTP 404）：请检查同步服务器地址是否正确。"
            .. detail
    elseif status == 405 then
        return "同步接口调用方式错误（HTTP 405）：同步接口只接受 POST。"
            .. detail
    elseif status == 409 then
        return "同步状态冲突（HTTP 409）：可能另一台设备正在同步，或本地数据"
            .. "需要整库同步。请稍后重试；若反复出现，请在设置里选择整库同步。"
            .. detail
    elseif status == 500 then
        return "AnkiWeb 服务器内部错误（HTTP 500）：请稍后重试。" .. detail
    elseif status == 501 then
        return "客户端版本不被支持（HTTP 501）：请更新 Kindlearnki 插件后"
            .. "重试。" .. detail
    elseif status == 503 then
        return "AnkiWeb 服务器繁忙（HTTP 503）：请稍后重试。" .. detail
    end
    return "同步请求失败（HTTP " .. tostring(status) .. "）：请稍后重试。"
        .. detail
end

--==========================================================================
-- Construction
--==========================================================================

--- @tparam table opts
--   endpoint        base URL, default `protocol.ENDPOINT_DEFAULT`
--   hkey            host key; empty before login
--   client_version  plugin version, default `protocol.VERSION`
--   transport       required: `{ request = function(request) ... end }`
function Client.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Client)
    self.endpoint = normalize_endpoint(opts.endpoint)
    self.hkey = tostring(opts.hkey or "")
    self.client_version = tostring(opts.client_version or protocol.VERSION)
    self.transport = opts.transport
    self.session = new_session_key()
    self.stats = { requests = 0 }
    return self
end

function Client:url_for(method)
    return self.endpoint .. "sync/" .. tostring(method):gsub("^/+", "")
end

--- The `anki-sync` header value for the current state.
function Client:header_json(hkey)
    return protocol.header_json(hkey or self.hkey, self.session,
        self.client_version)
end

function Client:_headers(hkey)
    return {
        ["anki-sync"] = self:header_json(hkey),
        ["content-type"] = "application/octet-stream",
    }
end

--==========================================================================
-- Transport plumbing
--==========================================================================

local function send(transport, request)
    if type(transport) == "function" then
        return transport(request)
    end
    return transport.request(request)
end

--[[-- Work out where a 308 points.
--
-- Returns `(new_base, next_url)`:
--   * an absolute Location is the per-user host base URL; persist it on the
--     client so every later request goes straight there;
--   * a path-absolute or relative Location (only seen from proxies) is
--     resolved for this one request and does not replace the base.
]]
local function redirect_target(location, current_url, endpoint, method)
    if location:match("^https?://") then
        -- AnkiWeb sends the base ("https://sync10.ankiweb.net/"). Tolerate a
        -- full route URL as well: strip the trailing sync/<method> part.
        local base = location:gsub("/sync/[%w]+/?$", "/")
        if base:sub(-1) ~= "/" then
            base = base .. "/"
        end
        return base, base .. "sync/" .. method
    end
    if location:sub(1, 1) == "/" then
        local origin = current_url:match("^(https?://[^/]+)")
        return nil, (origin or endpoint:gsub("/$", "")) .. location
    end
    return nil, endpoint .. location
end

--- POST one route and return `body, headers`, or `nil, message`.
--
-- `opts.hkey` overrides the host key in the header (login sends an empty one).
function Client:_request(method, body, opts)
    opts = opts or {}
    if self.transport == nil then
        return nil, "同步未配置网络传输（transport）：插件初始化不完整，"
            .. "请重启 KOReader 后重试。"
    end

    local url = self:url_for(method)
    local redirects = 0

    while true do
        local request = {
            url = url,
            method = "POST",
            headers = self:_headers(opts.hkey),
            body = body,
        }

        self.stats.requests = self.stats.requests + 1
        local called, response, transport_error = pcall(send, self.transport,
            request)
        if not called then
            return nil, "网络请求失败：插件内部错误（" .. tostring(response)
                .. "）。请重启 KOReader 后重试。"
        end
        if type(response) ~= "table" then
            return nil, network_error(transport_error or response)
        end

        local status = tonumber(response.status)
        if not status then
            return nil, "网络请求失败：服务器的响应缺少 HTTP 状态码，"
                .. "请稍后重试。"
        end
        local response_body = response.body or ""
        local response_headers = response.headers or {}

        if REDIRECT_STATUS[status] then
            redirects = redirects + 1
            if redirects > Client.MAX_REDIRECTS then
                return nil, string.format(
                    "同步重定向次数过多（超过 %d 次）：请检查同步服务器地址"
                        .. "是否正确，或稍后重试。", Client.MAX_REDIRECTS)
            end
            local location = header_value(response_headers, "location")
            if type(location) ~= "string" or location == "" then
                return nil, string.format(
                    "同步主机校验失败（HTTP %d）：服务器未给出跳转地址，"
                        .. "请重试一次；反复出现请重新登录。", status)
            end
            local new_base, next_url = redirect_target(location, url,
                self.endpoint, method)
            if new_base then
                -- Persist the assignment: AnkiWeb expects the following
                -- requests of this session on the same host.
                self.endpoint = new_base
            end
            url = next_url
        elseif status >= 200 and status < 300 then
            return response_body, response_headers
        else
            return nil, status_error(status, response_body)
        end
    end
end

--- Learn which sync host this account is assigned to.
--
-- AnkiWeb answers `/sync/meta` with a 308 whose Location points at
-- `sync{N}.ankiweb.net`; every other endpoint answers 303 with the body "303"
-- and **no Location** when asked on the wrong host.  A first full download has
-- no earlier request to learn the host from, so it must call this first.
function Client:resolve_host()
    if self.host_resolved then
        return true
    end
    local meta, err = self:meta()
    if meta == nil then
        return nil, err
    end
    self.host_resolved = true
    return true
end

--- Compress a JSON request body and POST it.
-- @return string compiled request body (for tests/logging)
function Client:_encode_body(json_text)
    local compressed, err = zstd.compress(json_text)
    if not compressed then
        return nil, err
    end
    return compressed
end

--- POST a zstd-wrapped JSON request and decode the JSON response.
-- @tparam string method route name
-- @tparam string json_text encoded request body
-- @treturn any|nil decoded value (JSON null arrives as nil)
-- @treturn string|nil Chinese error message
function Client:_post_json(method, json_text, opts)
    local compressed, compress_error = self:_encode_body(json_text)
    if not compressed then
        return nil, compress_error
    end

    local raw, request_error = self:_request(method, compressed, opts)
    if not raw then
        return nil, request_error
    end
    if raw == "" then
        return nil, "同步响应为空：服务器没有返回数据，请重试。"
    end

    local text, decompress_error = zstd.decompress(raw)
    if not text then
        return nil, decompress_error
    end
    if text == "" then
        return nil, "同步响应为空：服务器返回的数据无法解压，请重试。"
    end

    local decoded, value = pcall(json.decode, text)
    if not decoded then
        return nil, "同步响应格式错误：服务器返回的不是合法 JSON，请稍后"
            .. "重试。" .. body_snippet(text)
    end
    return value
end

--- POST a request whose response body we do not need to decode.
function Client:_post_ack(method, json_text, opts)
    local compressed, compress_error = self:_encode_body(json_text)
    if not compressed then
        return nil, compress_error
    end
    local response, request_error = self:_request(method, compressed, opts)
    if not response then
        return nil, request_error
    end
    return true
end

local function expect_table(value, method)
    if type(value) ~= "table" then
        return nil, method .. " 响应格式错误：服务器没有返回 JSON 对象，"
            .. "请稍后重试。"
    end
    return value
end

--==========================================================================
-- Routes
--==========================================================================

--- `/sync/hostKey`: exchange email/password for a host key.
--
-- The header must carry an *empty* `k`; AnkiWeb answers 403 otherwise.
function Client:host_key(email, password)
    local body = protocol.body_host_key(email, password)
    local response, err = self:_post_json("hostKey", body, { hkey = "" })
    if not response then
        return nil, err or "登录失败：服务器返回了空响应。请稍后重试。"
    end
    local key = type(response) == "table" and response.key
    if type(key) ~= "string" or key == "" then
        return nil, "登录失败：AnkiWeb 没有返回有效的 host key。"
            .. "请检查邮箱和密码，或稍后重试。"
    end
    self.hkey = key
    return key
end

--- `/sync/meta`: handshake; also follows the per-user 308 automatically.
function Client:meta()
    local response, err = self:_post_json("meta", protocol.body_meta(
        self.client_version))
    if not response then
        return nil, err
    end
    return expect_table(response, "meta")
end

--- `/sync/start`: begin the incremental sync, returning server-side graves.
function Client:start(min_usn, local_is_newer)
    local body = protocol.body_start(min_usn, local_is_newer)
    local response, err = self:_post_json("start", body)
    if not response then
        return nil, err
    end
    local graves, format_error = expect_table(response, "start")
    if not graves then
        return nil, format_error
    end
    -- serde's `default` lets the server omit empty lists entirely; the caller
    -- iterates them, so give it stable empty tables.
    return {
        cards = graves.cards or {},
        notes = graves.notes or {},
        decks = graves.decks or {},
    }
end

--- `/sync/applyChanges`: exchange model/deck/tag changes.
-- @tparam[opt] table changes decoded `UnchunkedChanges`, nil for an empty sync
function Client:apply_changes(changes)
    local body = protocol.body_apply_changes(changes)
    local response, err = self:_post_json("applyChanges", body)
    if not response then
        return nil, err
    end
    local remote, format_error = expect_table(response, "applyChanges")
    if not remote then
        return nil, format_error
    end
    return {
        models = remote.models or {},
        decks = remote.decks or {},
        tags = remote.tags or {},
    }
end

--- `/sync/chunk`: pull one chunk of remote changes.
function Client:chunk()
    local response, err = self:_post_json("chunk", protocol.body_empty())
    if not response then
        return nil, err
    end
    return expect_table(response, "chunk")
end

--- `/sync/applyChunk`: push one chunk of local changes.
--
-- The response is an empty JSON value (`null`), which is why this route does
-- not go through `_post_json` -- nil would be indistinguishable from success.
function Client:apply_chunk(chunk)
    local body = protocol.body_apply_chunk(chunk)
    local ok, err = self:_post_ack("applyChunk", body)
    if not ok then
        return nil, err
    end
    return true
end

--- `/sync/sanityCheck2`: compare row counts with the server.
-- @tparam table payload positional counts from `protocol.sanity_counts`, or a
--   named table `{ cards=, notes=, revlog=, graves=, notetypes=, decks=,
--   deck_config= }`
-- @treturn string|nil `"ok"` or `"bad"`
-- @treturn string|nil Chinese error message
-- @treturn table|nil the full server response (for diagnostics)
function Client:sanity_check2(payload)
    if type(payload) ~= "table" then
        return nil, "sanityCheck2 需要计数表（protocol.sanity_counts 的结果）。"
    end
    local counts
    if payload[1] ~= nil then
        counts = payload
    else
        counts = protocol.sanity_counts(payload.cards, payload.notes,
            payload.revlog, payload.graves or payload.graves_count, payload)
    end

    local response, err = self:_post_json("sanityCheck2",
        protocol.body_sanity_check2(counts))
    if not response then
        return nil, err
    end
    local reply, format_error = expect_table(response, "sanityCheck2")
    if not reply then
        return nil, format_error
    end
    local status = reply.status
    if type(status) ~= "string" then
        return nil, "sanityCheck2 响应缺少 status 字段，请稍后重试。"
    end
    return status, nil, reply
end

--- `/sync/finish`: end the incremental sync; returns the new server mod time.
function Client:finish()
    local response, err = self:_post_json("finish", protocol.body_empty())
    if not response then
        return nil, err
    end
    if type(response) ~= "number" then
        return nil, "finish 响应格式错误：服务器没有返回同步完成时间，"
            .. "请稍后重试。"
    end
    return response
end

--- `/sync/abort`: best-effort cancellation of an in-flight session.
function Client:abort()
    local ok, err = self:_post_ack("abort", protocol.body_empty())
    if not ok then
        return nil, err
    end
    return true
end

--- `/sync/upload`: replace the server collection with `bytes` (raw sqlite).
--
-- The body is the *zstd frame* of the collection, and the response is the
-- bare text `"OK"` (also zstd-wrapped in protocol v11), not JSON. Any other
-- text is the server's upload rejection reason and is surfaced verbatim.
--
-- A caller that already has a frame (the streaming `zstd.compress_file` path,
-- which never holds the whole collection in memory) may pass it directly: a
-- raw sqlite file always starts with `SQLite format 3\0`, so the zstd magic
-- number is unambiguous.
function Client:upload(bytes)
    if type(bytes) ~= "string" then
        return nil, "upload 需要原始数据库字节（字符串）。"
    end
    local compressed
    if bytes:sub(1, 4) == ZSTD_MAGIC then
        compressed = bytes
    else
        local compress_error
        compressed, compress_error = self:_encode_body(bytes)
        if not compressed then
            return nil, compress_error
        end
    end

    local raw, request_error = self:_request("upload", compressed)
    if not raw then
        return nil, request_error
    end
    local text, decompress_error = zstd.decompress(raw)
    if not text then
        return nil, "上传响应无法解压：" .. tostring(decompress_error)
    end
    local reply = text:match("^%s*(.-)%s*$")
    if reply == "OK" then
        return true
    end
    if reply == "" then
        return nil, "上传失败：服务器返回了空响应，请稍后重试。"
    end
    return nil, "上传失败：" .. reply:sub(1, 200)
end

--- `/sync/download`: fetch the server collection (raw sqlite bytes).
--
-- On the wire the response is a zstd frame; after decompression it is the raw
-- sqlite file, not JSON.
function Client:download()
    local compressed, compress_error = self:_encode_body(protocol.body_empty())
    if not compressed then
        return nil, compress_error
    end
    local raw, request_error = self:_request("download", compressed)
    if not raw then
        return nil, request_error
    end
    if raw == "" then
        return nil, "下载失败：服务器返回了空响应，请稍后重试。"
    end
    local bytes, decompress_error = zstd.decompress(raw)
    if not bytes then
        return nil, "下载数据无法解压，同步未完成，请重试。（" .. tostring(
            decompress_error) .. "）"
    end
    if bytes == "" then
        return nil, "下载失败：服务器返回的数据库为空，同步未完成，请重试。"
    end
    return bytes
end

return Client
