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

--- @tparam table opts { url, method, headers = {}, body, cafile, timeout }
-- @treturn table { status = number, headers = table, body = string }
-- @treturn nil, string  on transport failure
function Transport.request(opts)
    local ltn12 = require("ltn12")
    local sink = {}
    local headers = {}
    for key, value in pairs(opts.headers or {}) do
        headers[string.lower(key)] = tostring(value)
    end

    local theme = {
        url = opts.url,
        method = opts.method or "POST",
        headers = headers,
        source = ltn12.source.string(opts.body or ""),
        sink = ltn12.sink.table(sink),
        verify = "peer",
        cafile = opts.cafile or Transport.default_cafile(),
        protocol = "any",
        options = "all",
    }

    local is_https = opts.url:sub(1, 6) == "https:"
    local ok, _, code, response_headers
    if is_https then
        local https = require("ssl.https")
        https.TIMEOUT = opts.timeout or Transport.TIMEOUT
        ok, _, code, response_headers = pcall(https.request, theme)
    else
        local http = require("socket.http")
        http.TIMEOUT = opts.timeout or Transport.TIMEOUT
        ok, _, code, response_headers = pcall(http.request, theme)
    end

    if not ok then
        -- LuaSec raises for a bad cafile or an unsupported option; surface it
        -- rather than silently retrying without verification.
        return nil, "请求失败：" .. tostring(_)
    end
    if not code then
        return nil, "网络不可用（" .. tostring(_) .. "）"
    end
    if type(code) ~= "number" then
        return nil, "响应异常：" .. tostring(code)
    end

    local normalised = {}
    for key, value in pairs(response_headers or {}) do
        normalised[string.lower(key)] = value
    end
    return {
        status = code,
        headers = normalised,
        body = table.concat(sink),
    }
end

return Transport
