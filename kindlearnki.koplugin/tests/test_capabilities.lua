local Capabilities = require("core.capabilities")

local function no_host()
    error("no KOReader here", 0)
end

return {
    ["a complete host is reported as ok"] = function()
        local result = Capabilities.probe{
            require_fn = no_host,
            overrides = { html = true, sqlite = true, zstd = true, ca = true },
            ko_version = "2026.07.1-1",
            model = "KindleVoyage",
        }
        assert(result.ok)
        assert(#result.missing == 0)
        assert(result.summary:find("html=ok sqlite=ok", 1, true), result.summary)
        assert(result.summary:find("zstd=ok ca=yes", 1, true), result.summary)
        assert(result.summary:find("model=KindleVoyage", 1, true), result.summary)
    end,

    ["a missing HTML renderer is named and flips ok"] = function()
        local result = Capabilities.probe{
            require_fn = no_host,
            overrides = { html = false, sqlite = true, zstd = true, ca = true },
        }
        assert(not result.ok)
        assert(result.missing[1] == "html", result.missing[1])
        assert(result.summary:find("html=no", 1, true), result.summary)
    end,

    ["a missing database is named and flips ok"] = function()
        local result = Capabilities.probe{
            require_fn = no_host,
            overrides = { html = true, sqlite = false, zstd = true, ca = false },
        }
        assert(not result.ok)
        assert(result.missing[1] == "sqlite")
        assert(result.summary:find("ca=no", 1, true), result.summary)
    end,

    ["a host whose require always fails does not throw"] = function()
        local result = Capabilities.probe{
            require_fn = no_host,
            ca_path = "Z:/definitely/not/here/ca-bundle.crt",
        }
        assert(not result.ok)
        assert(result.values.sqlite == false)
        assert(result.values.html == false)
        assert(type(result.summary) == "string")
    end,

    ["the CA probe rejects an absent bundle"] = function()
        local result = Capabilities.probe{
            require_fn = no_host,
            overrides = { html = true, sqlite = true, zstd = true },
            ca_path = "Z:/definitely/not/here/ca-bundle.crt",
        }
        assert(result.values.ca == false)
        assert(result.summary:find("ca=no", 1, true), result.summary)
    end,
}
