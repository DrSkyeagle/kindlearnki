-- Single source of truth for the release identity.
--
-- `_meta.lua` and `main.lua` carry the same string for KOReader's plugin
-- manager, and `tests/test_version.lua` fails if they drift.  Bump all three
-- together.
--
-- MIN_KOREADER is the first release we verified for the HTML path
-- (`HtmlBoxWidget:setContent(..., html_resource_directory)`); older builds
-- print raw markup instead of rendering it.

return {
    PRODUCT = "Kindle Anki",
    VERSION = "0.2.16",
    MIN_KOREADER = { 2026, 7, 1 },
}


