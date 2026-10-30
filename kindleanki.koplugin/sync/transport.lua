-- KOReader HTTP transport for sync (LuaSocket/LuaSec).
--
-- The sync client takes a transport table so it can be unit tested without
-- sockets; this is the production implementation.  Two things matter:
--
--  1. **Certificate verification is explicit.**  KOReader's own https wrapper
--     ships `verify = "none"`; inheriting that would put the AnkiWeb password
--     and the host key on an unauthenticated channel.  We always pass the
--     bundled CA file and `verify = "peer"`.
--  2. **One request, one result.**  No implicit retries: a sync request that
--     may have reached the server twice would duplicate chunks.
--
-- Every stage is logged.  A hard crash in the native TLS stack cannot be caught
-- by pcall, so the only evidence left is the last stage in crash.log; the log
-- line before each call is deliberate.

local Log = require("core.log")

local Transport = {}

Transport.TIMEOUT = 60 -- seconds; the Kindle's radio is slow, but not this slow

--- Path of KOReader's CA bundle.
function Transport.default_cafile()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        local ok_dir, dir = pcall(function()
            return DataStorage:getDataDir()
        end)
        if ok_dir and dir then
            return dir .. "/data/ca-bundle.crt"
        end
    end
    return "data/ca-bundle.crt"
end

local function apply_timeouts(seconds)
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket then
        pcall(function()
            socket.core
        end)
    end
    -- KOReader's socketutil sets both the connect timeout and the per-block
    -- timeout; LuaSocket's own TIMEOUT only covers the latter.
    pcall(function()
        local socketutil = require("socketutil")
        socketutil:set_timeout(seconds, seconds, seconds * 2)
    end)
end

--- @tparam table opts { url, method, headers = {}, body, cafile, timeout }
-- @treturn table { status = number, headers = table, body = string }
-- @treturn nil, string  on transport failure
function Transport.request(opts)
    local cafile = opts.cafile or Transport.default_cafile()
    local timeout = opts.timeout or Transport.TIMEOUT

    Log.info("http: request", tostring(opts.method or "POST"),
        tostring(opts.url), "body=" .. tostring(#(opts.body or "")),
        "cafile=" .. tostring(cafile))

    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 then
        Log.err("http: ltn12 unavailable:", tostring(ltn12))
        return nil, "网络组件缺失（ltn12）"
    end

    local sink = {}
    local headers = {}
    for key, value in pairs(opts.headers or {}) do
        headers[string.lower(key)] = tostring(value)
    end

    local request = {
        url = opts.url,
        method = opts.method or "POST",
        headers = headers,
        source = ltn12.source.string(opts.body or ""),
        sink = ltn12.sink.table(sink),
        verify = "peer",
        cafile = cafile,
        protocol = "any",
        options = "all",
    }

    apply_timeouts(timeout)

    local is_https = opts.url:sub(1, 6) == "https:"
    local started = os.time()
    local call_ok, first, second, third

    if is_https then
        local ok_ssl, https = pcall(require, "ssl.https")
        if not ok_ssl then
            Log.err("http: ssl.https unavailable:", tostring(https))
            return nil, "网络组件缺失（ssl.https）"
        end
        https.TIMEOUT = timeout
        Log.info("http: connecting (https)")
        call_ok, first, second, third = pcall(https.request, request)
    else
        local ok_http, http = pcall(require, "socket.http")
        if not ok_http then
            Log.err("http: socket.http unavailable:", tostring(http))
            return nil, "网络组件缺失（socket.http）"
        end
        http.TIMEOUT = timeout
        Log.info("http: connecting (http)")
        call_ok, first, second, third = pcall(http.request, request)
    end

    --[[ LuaSocket/LuaSec return `1, code, headers, status` on success and
    `nil, err` on a transport failure.  A raised error arrives as
    `false, message`.  Keeping the three shapes apart here is what makes the log
    line readable when a device-only failure happens. ]]
    local code, response_headers
    if not call_ok then
        Log.err("http: request raised:", tostring(first))
        return nil, "请求失败：" .. tostring(first)
    elseif first == nil then
        Log.err("http: transport failed:", tostring(second))
        return nil, "网络不可用（" .. tostring(second) .. "）"
    elseif type(first) == "number" then
        code = second
        response_headers = third
    else
        -- Some wrappers return `code, headers, body`.
        code = first
        response_headers = second
    end

    Log.info("http: returned after", tostring(os.time() - started), "s",
        "code=" .. tostring(code))

    if not code then
        Log.err("http: no status code")
        return nil, "网络不可用（无响应）"
    end
    if type(code) ~= "number" then
        Log.err("http: non-numeric status:", tostring(code))
        return nil, "响应异常：" .. tostring(code)
    end

    local normalised = {}
    for key, value in pairs(response_headers or {}) do
        normalised[string.lower(key)] = value
    end
    local body = table.concat(sink)
    Log.info("http: response", tostring(code), "bytes=" .. tostring(#body))
    return {
        status = code,
        headers = normalised,
        body = body,
    }
end

--- Minimal reachability probe used by the "网络诊断" menu item.
-- Returns a list of `{ stage = ..., ok = bool, detail = ... }`; it never raises.
function Transport.selftest(host)
    host = host or "sync.ankiweb.net"
    local steps = {}
    local function record(stage, ok, detail)
        steps[#steps + 1] = { stage = stage, ok = ok and true or false,
            detail = detail }
        Log.info("selftest:", stage, ok and "ok" or "FAIL", tostring(detail))
    end

    local ok_socket, socket = pcall(require, "socket")
    record("require socket", ok_socket, tostring(socket))
    if not ok_socket or type(socket) ~= "table" then
        return steps
    end

    local tcp
    local ok_conn, conn = pcall(function()
        tcp = socket.tcp()
        tcp:settimeout(8)
        return tcp:connect(host, 443)
    end)
    record("tcp connect " .. host .. ":443", ok_conn and conn == 1,
        tostring(conn))

    if not (ok_conn and conn == 1) then
        return steps
    end

    local ok_ssl, ssl = pcall(require, "ssl")
    record("require ssl", ok_ssl, tostring(ssl))
    if not ok_ssl then
        pcall(function() tcp:close() end)
        return steps
    end

    local cafile = Transport.default_cafile()
    local ok_wrap, secure = pcall(ssl.wrap, tcp, {
        mode = "client",
        protocol = "any",
        verify = "peer",
        cafile = cafile,
        options = "all",
    })
    record("ssl.wrap", ok_wrap, tostring(secure))
    if not ok_wrap or not secure then
        pcall(function() tcp:close() end)
        return steps
    end

    secure:settimeout(8)
    local ok_handshake, handshake = pcall(secure.dohandshake, secure)
    record("tls handshake", ok_handshake, tostring(handshake))
    pcall(function() secure:close() end)
    return steps
end

return Transport
