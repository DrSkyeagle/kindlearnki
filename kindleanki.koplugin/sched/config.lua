-- Anki v3 deck-config defaults and protobuf decoding.
--
-- Field numbers: anki-26.09.3/proto/anki/deck_config.proto (DeckConfig.Config).
-- Defaults: rslib/src/deckconfig/mod.rs:41-103.  proto3 omits zero values, so
-- every absent field must fall back to the Rust default rather than to 0 —
-- getting this wrong turns "hard multiplier 1.2" into "0.0" and every interval
-- into 1 day.

local PB = require("proto.pb")

local Config = {}

Config.DEFAULTS = {
    learn_steps = { 1.0, 10.0 },
    relearn_steps = { 10.0 },
    new_per_day = 20,
    reviews_per_day = 200,
    initial_ease = 2.5,
    easy_multiplier = 1.3,
    hard_multiplier = 1.2,
    lapse_multiplier = 0.0,
    interval_multiplier = 1.0,
    maximum_review_interval = 36500,
    minimum_lapse_interval = 1,
    graduating_interval_good = 1,
    graduating_interval_easy = 4,
    new_card_insert_order = 0,
    new_card_gather_priority = 0,
    new_card_sort_order = 0,
    review_order = 0,
    new_mix = 0,
    interday_learning_mix = 0,
    leech_action = 1, -- TagOnly (the Rust default; proto0 would mean Suspend)
    leech_threshold = 8,
    bury_new = false,
    bury_reviews = false,
    bury_interday_learning = false,
    desired_retention = 0.9,
}

--- Decode a `deck_config.config` blob.
function Config.decode(blob)
    local message = PB.decode(blob or "")
    local config = {}
    for key, value in pairs(Config.DEFAULTS) do
        config[key] = value
    end

    local steps = PB.repeated_float(message, 1)
    if #steps > 0 then
        config.learn_steps = steps
    end
    local relearn = PB.repeated_float(message, 2)
    if #relearn > 0 then
        config.relearn_steps = relearn
    end

    config.new_per_day = PB.uint(message, 9, config.new_per_day)
    config.reviews_per_day = PB.uint(message, 10, config.reviews_per_day)
    config.initial_ease = PB.float(message, 11, config.initial_ease)
    config.easy_multiplier = PB.float(message, 12, config.easy_multiplier)
    config.hard_multiplier = PB.float(message, 13, config.hard_multiplier)
    config.lapse_multiplier = PB.float(message, 14, config.lapse_multiplier)
    config.interval_multiplier = PB.float(message, 15, config.interval_multiplier)
    config.maximum_review_interval = PB.uint(message, 16, config.maximum_review_interval)
    config.minimum_lapse_interval = PB.uint(message, 17, config.minimum_lapse_interval)
    config.graduating_interval_good = PB.uint(message, 18, config.graduating_interval_good)
    config.graduating_interval_easy = PB.uint(message, 19, config.graduating_interval_easy)
    config.new_card_insert_order = PB.uint(message, 20, config.new_card_insert_order)
    config.leech_action = PB.uint(message, 21, config.leech_action)
    config.leech_threshold = PB.uint(message, 22, config.leech_threshold)
    config.bury_new = PB.bool(message, 27, config.bury_new)
    config.bury_reviews = PB.bool(message, 28, config.bury_reviews)
    config.bury_interday_learning = PB.bool(message, 29, config.bury_interday_learning)
    config.new_mix = PB.uint(message, 30, config.new_mix)
    config.interday_learning_mix = PB.uint(message, 31, config.interday_learning_mix)
    config.new_card_sort_order = PB.uint(message, 32, config.new_card_sort_order)
    config.review_order = PB.uint(message, 33, config.review_order)
    config.new_card_gather_priority = PB.uint(message, 34, config.new_card_gather_priority)
    config.desired_retention = PB.float(message, 37, config.desired_retention)

    return config
end

return Config
