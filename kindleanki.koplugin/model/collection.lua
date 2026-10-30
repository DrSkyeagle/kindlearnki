-- Read model over a schema-18 collection.
--
-- Only the tables this plugin needs are decoded; everything else is left
-- untouched, and unknown protobuf fields are never written back.  A collection
-- that a newer desktop Anki has upgraded must remain safe to read (with fields
-- we do not understand simply ignored).

local Conn = require("db.conn")
local Collation = require("db.collation")
local PB = require("proto.pb")
local Config = require("sched.config")
local Timing = require("sched.timing")

local Collection = {}
local MT = { __index = Collection }

local function decode_config_value(raw)
    if raw == nil then
        return nil
    end
    if raw == "true" then
        return true
    elseif raw == "false" then
        return false
    end
    local number = tonumber(raw)
    if number then
        return number
    end
    if raw:sub(1, 1) == '"' then
        return raw:sub(2, -2)
    end
    return raw
end

--- @string path
-- @tparam table opts { read_only = false }
function Collection.open(path, opts)
    opts = opts or {}
    local self = setmetatable({ path = path }, MT)
    self.conn = Conn.open(path, opts.read_only)

    local ok, err = Collation.install(self.conn)
    self.collation = ok and true or false
    self.collation_error = ok and nil or tostring(err)

    self:load_meta()
    return self
end

function Collection:load_meta()
    local row = self.conn:first("select crt, mod, scm, usn, ls, ver from col")
    if not row then
        error("collection has no col row: " .. tostring(self.path))
    end
    self.created = row[1]
    self.modified = row[2]
    self.schema_modified = row[3]
    self.usn = row[4]
    self.ls = row[5]
    self.ver = row[6]
    if self.ver ~= 18 then
        error(string.format(
            "不支持的集合结构版本 %s（需要 18）：请先用桌面 Anki 26.x 同步一次",
            tostring(self.ver)))
    end

    self.config = {}
    for _, config_row in ipairs(self.conn:all("select KEY, val from config")) do
        self.config[config_row[1]] = decode_config_value(config_row[2])
    end

    self.decks = {}
    self.decks_by_id = {}
    self.deck_configs = {}
end

function Collection:rollover_hour()
    local hour = tonumber(self.config.rollover)
    return hour or 4
end

function Collection:created_offset()
    return Timing.minutes_west_to_offset_seconds(
        tonumber(self.config.creationOffset) or 0)
end

--- Current UTC offset in seconds east; falls back to the stored localOffset.
function Collection:now_offset(now)
    local computed = Timing.utc_offset(now)
    if computed == 0 and tonumber(self.config.localOffset) then
        return Timing.minutes_west_to_offset_seconds(
            tonumber(self.config.localOffset))
    end
    return computed
end

--- v3 `days_elapsed` for this collection at `now`.
function Collection:days_elapsed(now)
    now = now or os.time()
    return Timing.days_elapsed{
        created = self.created,
        created_offset = self:created_offset(),
        now = now,
        now_offset = self:now_offset(now),
        rollover_hour = self:rollover_hour(),
    }
end

--==========================================================================
-- Decks
--==========================================================================

--- Anki stores the deck hierarchy separator as 0x1f; the UI expects "::".
function Collection.printable_deck_name(name)
    return (tostring(name or ""):gsub(string.char(31), "::"))
end

function Collection:load_decks()
    if self.decks_loaded then
        return
    end
    self.decks_loaded = true

    for _, row in ipairs(self.conn:all("select id, name, common, kind from decks")) do
        local id, name, common_blob, kind_blob = row[1], row[2], row[3], row[4]
        local kind = PB.decode(kind_blob or "")
        -- Deck.kind is a oneof: field 1 = Normal (whose field 1 is config_id),
        -- field 2 = Filtered.
        local normal = PB.message(kind, 1)
        -- Anki stores the hierarchy separator as 0x1f in the database; the UI
        -- (and every "::" pattern here) expects the printable form.
        local printable_name = Collection.printable_deck_name(name)
        local deck = {
            id = id,
            name = printable_name,
            common_blob = common_blob,
            filter_id = PB.message(kind, 2) and id or nil,
            config_id = normal and PB.uint(normal, 1, 1) or 1,
            children = {},
        }
        self.decks[#self.decks + 1] = deck
        self.decks_by_id[id] = deck
    end

    -- Parent/child links from the "::" naming convention, like Anki.
    for _, deck in ipairs(self.decks) do
        local parent_name = deck.name:match("^(.*)::[^:]+$")
        if parent_name then
            for _, candidate in ipairs(self.decks) do
                if candidate.name == parent_name then
                    deck.parent = candidate
                    candidate.children[#candidate.children + 1] = deck
                    break
                end
            end
        end
    end

    for _, row in ipairs(self.conn:all("select id, config from deck_config")) do
        self.deck_configs[row[1]] = Config.decode(row[2])
    end
end

function Collection:deck(id)
    self:load_decks()
    return self.decks_by_id[id]
end

--- Deck plus every descendant id (Anki counts include subdecks).
function Collection:deck_subtree_ids(deck_id)
    self:load_decks()
    local ids = {}
    local function visit(deck)
        ids[#ids + 1] = deck.id
        for _, child in ipairs(deck.children) do
            visit(child)
        end
    end
    local root = self.decks_by_id[deck_id]
    if not root then
        return ids
    end
    visit(root)
    return ids
end

function Collection:deck_config(deck_or_config_id)
    self:load_decks()
    local config_id = type(deck_or_config_id) == "table"
        and deck_or_config_id.config_id or deck_or_config_id
    local config = self.deck_configs[config_id]
    if config then
        return config
    end
    -- A deck may point at a missing config; fall back to the defaults rather
    -- than failing the whole review session.
    return Config.decode("")
end

function Collection:active_deck_id()
    local active = self.config.activeDecks
    if type(active) == "table" and active[1] then
        return active[1]
    end
    if type(active) == "string" then
        local first = active:match("%d+")
        if first then
            return tonumber(first)
        end
    end
    return tonumber(self.config.curDeck) or 1
end

--==========================================================================
-- Notetypes (needed by the renderer)
--==========================================================================

function Collection:notetype(ntid)
    self.notetypes = self.notetypes or {}
    local cached = self.notetypes[ntid]
    if cached then
        return cached
    end

    local row = self.conn:first("select config from notetypes where id = ?", ntid)
    if not row then
        return nil
    end
    local config = PB.decode(row[1] or "")

    local fields = {}
    for _, field_row in ipairs(self.conn:all(
        "select ord, name from fields where ntid = ? order by ord", ntid)) do
        fields[#fields + 1] = { ord = field_row[1], name = field_row[2] }
    end

    local templates = {}
    for _, template_row in ipairs(self.conn:all(
        "select ord, name, config from templates where ntid = ? order by ord",
        ntid)) do
        local template_config = PB.decode(template_row[3] or "")
        templates[#templates + 1] = {
            ord = template_row[1],
            name = template_row[2],
            qfmt = PB.string(template_config, 1, ""),
            afmt = PB.string(template_config, 2, ""),
        }
    end

    local notetype = {
        id = ntid,
        kind = PB.uint(config, 1, 0),
        sort_field_idx = PB.uint(config, 2, 0),
        css = PB.string(config, 3, ""),
        fields = fields,
        templates = templates,
    }
    self.notetypes[ntid] = notetype
    return notetype
end

--==========================================================================
-- Notes (needed by the renderer)
--==========================================================================

--- @treturn table|nil { id, guid, mid, mod, usn, tags, fields = {...}, sfld, csum }
function Collection:note(nid)
    local row = self.conn:first(
        "select id, guid, mid, mod, usn, tags, flds, sfld, csum from notes where id = ?",
        nid)
    if not row then
        return nil
    end
    local fields = {}
    for value in (row[7] .. "\31"):gmatch("(.-)\31") do
        fields[#fields + 1] = value
    end
    return {
        id = row[1],
        guid = row[2],
        mid = row[3],
        mod = row[4],
        usn = row[5],
        tags = row[6],
        fields = fields,
        -- schema 18 stores sfld as an integer column even though the wire
        -- format uses a string; keep the raw value for the renderer.
        sfld = row[8],
        csum = row[9],
    }
end

--==========================================================================
-- Cards
--==========================================================================

Collection.CARD_COLUMNS =
    "id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"

function Collection:card(row)
    return {
        id = row[1],
        nid = row[2],
        did = row[3],
        ord = row[4],
        mod = row[5],
        usn = row[6],
        type = row[7],
        queue = row[8],
        due = row[9],
        ivl = row[10],
        factor = row[11],
        reps = row[12],
        lapses = row[13],
        left = row[14],
        odue = row[15],
        odid = row[16],
        flags = row[17],
        data = row[18],
    }
end

function Collection:card_by_id(card_id)
    local row = self.conn:first(string.format(
        "select %s from cards where id = ?", Collection.CARD_COLUMNS), card_id)
    if not row then
        return nil
    end
    return self:card(row)
end

function Collection:cards_in_decks(deck_ids)
    local placeholders = {}
    for index = 1, #deck_ids do
        placeholders[index] = "?"
    end
    local sql = string.format(
        "select %s from cards where did in (%s)",
        Collection.CARD_COLUMNS, table.concat(placeholders, ","))
    local cards = {}
    for _, row in ipairs(self.conn:all(sql, unpack(deck_ids))) do
        cards[#cards + 1] = self:card(row)
    end
    return cards
end

--- Re-open after the file on disk was replaced (full sync download).
function Collection:reload()
    self:close()
    self.conn = Conn.open(self.path)
    local ok, err = Collation.install(self.conn)
    self.collation = ok and true or false
    self.collation_error = ok and nil or tostring(err)
    self.decks = {}
    self.decks_by_id = {}
    self.deck_configs = {}
    self.decks_loaded = false
    self.notetypes = {}
    self:load_meta()
end

function Collection:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

return Collection
