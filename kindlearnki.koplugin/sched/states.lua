-- v3 card states and their four possible answers.
--
-- Source of the maths: rslib/src/scheduler/states/{review,learning,relearning,
-- steps,fuzz}.rs and answering/mod.rs (fuzz seed).  Fuzz itself is random per
-- card (StdRng seeded with card_id + reps), so this module exposes the *raw*
-- interval and the allowed bounds instead of pretending it can reproduce the
-- exact value; the differential test asserts "inside the bounds".
--
-- Scope: new / learning / review / relearning.  Filtered decks, FSRS and the
-- load balancer are out of scope by decision (see doc/SCHED-SPEC.md).

local States = {}

local DAY = 86400

local MIN_EASE = 1.3
local EASE_AGAIN = -0.2
local EASE_HARD = -0.15
local EASE_EASY = 0.15

-- states/fuzz.rs:44-51
local FUZZ_RANGES = {
    { start = 2.5, finish = 7.0, factor = 0.15 },
    { start = 7.0, finish = 20.0, factor = 0.10 },
    { start = 20.0, finish = math.huge, factor = 0.05 },
}

function States.fuzz_delta(interval)
    if interval < 2.5 then
        return 0.0
    end
    local delta = 1.0
    for _, range in ipairs(FUZZ_RANGES) do
        delta = delta + range.factor * math.max(interval < range.finish and interval or range.finish - range.start, 0)
    end
    return delta
end

--- Allowed [lower, upper] for an interval after fuzz (states/fuzz.rs:117-135).
function States.fuzz_bounds(interval)
    local delta = States.fuzz_delta(interval)
    return math.floor(interval - delta + 0.5), math.floor(interval + delta + 0.5)
end

function States.constrained_bounds(interval, minimum, maximum)
    minimum = math.min(minimum, maximum)
    interval = math.max(minimum, math.min(interval, maximum))
    local lower, upper = States.fuzz_bounds(interval)
    lower = math.max(minimum, math.min(lower, maximum))
    upper = math.max(minimum, math.min(upper, maximum))
    if upper == lower and upper > 2 and upper < maximum then
        upper = lower + 1
    end
    return lower, upper
end

--- Clamp an interval the way `constrain_passing_interval` does.
function States.constrain(interval, minimum, maximum, apply_fuzz)
    interval = interval * 1.0 -- interval multiplier is applied by the caller
    local lower, upper
    minimum = math.max(1, math.min(minimum or 1, maximum))
    if apply_fuzz == false then
        lower = math.floor(interval + 0.5)
        upper = lower
    else
        lower, upper = States.constrained_bounds(interval, minimum, maximum)
    end
    local value = math.floor(interval + 0.5)
    if value < lower then
        value = lower
    elseif value > upper then
        value = upper
    end
    return value, lower, upper
end

--==========================================================================
-- Learning steps (states/steps.rs)
--==========================================================================

local Steps = {}
States.Steps = Steps

function Steps.new(list)
    return setmetatable({ values = list or {} }, { __index = Steps })
end

local function to_secs(minutes)
    return math.floor(minutes * 60)
end

function Steps:index(remaining)
    local total = #self.values
    local value = total - (remaining % 1000)
    if value > total - 1 then
        value = total - 1
    end
    if value < 0 then
        value = 0
    end
    return value
end

function Steps:again_delay()
    local first = self.values[1]
    return first and to_secs(first) or nil
end

local function maybe_round_in_days(secs)
    if secs > DAY then
        return math.floor(secs / DAY + 0.5) * DAY
    end
    return secs
end

function Steps:hard_delay(remaining)
    local values = self.values
    if #values == 0 then
        return nil
    end
    local index = self:index(remaining) + 1
    local current = values[index] and to_secs(values[index]) or to_secs(values[1])
    if index == 1 then
        if values[2] then
            return maybe_round_in_days(math.floor((current + to_secs(values[2])) / 2))
        end
        local secs = math.min(math.floor(current * 3 / 2), current + DAY)
        return maybe_round_in_days(secs)
    end
    return current
end

function Steps:good_delay(remaining)
    local index = self:index(remaining)
    local next_value = self.values[index + 2]
    return next_value and to_secs(next_value) or nil
end

function Steps:remaining_for_good(remaining)
    return #self.values - self:index(remaining) - 1
end

function Steps:remaining_for_failed()
    return #self.values
end

--==========================================================================
-- Card -> state
--==========================================================================

--- @tparam table card   row from db (type/queue/due/ivl/factor/reps/lapses/left)
--- @tparam number today  v3 days_elapsed
--- @tparam number now    UNIX seconds
function States.from_card(card, today, now)
    local card_type = card.type
    if card_type == 0 then
        return { kind = "new", position = card.due }
    end
    if card_type == 1 then
        return {
            kind = "learning",
            remaining_steps = card.left % 1000,
            scheduled_secs = math.max(0, card.due - now),
        }
    end
    if card_type == 2 then
        -- answering/current.rs:106-114: elapsed_days is "days since the last
        -- review", i.e. the interval already served plus the days overdue.
        -- (today - due) alone is only the overdue part and was 3 days short
        -- on the real fixture.
        local overdue = card.due - today
        return {
            kind = "review",
            scheduled_days = card.ivl,
            elapsed_days = math.max(0, card.ivl - overdue),
            ease_factor = card.factor / 1000,
            lapses = card.lapses,
        }
    end
    -- type 3: relearning
    return {
        kind = "relearning",
        remaining_steps = card.left % 1000,
        scheduled_secs = math.max(0, card.due - now),
        review = {
            scheduled_days = card.ivl,
            elapsed_days = card.ivl,
            ease_factor = card.factor / 1000,
            lapses = card.lapses,
        },
    }
end

--==========================================================================
-- Next states
--==========================================================================

local function learning_answer(state, config, ctx, which)
    local steps = Steps.new(config.learn_steps)
    local remaining = state.remaining_steps or #config.learn_steps
    local minimum, maximum = 1, math.max(1, config.maximum_review_interval)

    local function graduate(interval_days, ease)
        local raw = interval_days * config.interval_multiplier
        local value, lower, upper = States.constrain(raw, minimum, maximum, true)
        return {
            kind = "review",
            scheduled_days = math.floor(raw + 0.5),
            fuzz_lower = lower,
            fuzz_upper = upper,
            ease_factor = ease or config.initial_ease,
            lapses = 0,
        }
    end

    if which == "again" then
        local delay = steps:again_delay()
        if delay then
            return {
                kind = "learning",
                remaining_steps = steps:remaining_for_failed(),
                scheduled_secs = delay,
            }
        end
        return graduate(config.graduating_interval_good, config.initial_ease)
    elseif which == "hard" then
        local delay = steps:hard_delay(remaining)
        if delay then
            return {
                kind = "learning",
                remaining_steps = remaining,
                scheduled_secs = delay,
            }
        end
        return graduate(config.graduating_interval_good, config.initial_ease)
    elseif which == "good" then
        local delay = steps:good_delay(remaining)
        if delay then
            return {
                kind = "learning",
                remaining_steps = steps:remaining_for_good(remaining),
                scheduled_secs = delay,
            }
        end
        return graduate(config.graduating_interval_good, config.initial_ease)
    end
    return graduate(config.graduating_interval_easy, config.initial_ease)
end

local function review_answer(state, config, ctx, which)
    local current_interval = math.max(state.scheduled_days, 1)
    local days_late = math.max(0, state.elapsed_days - state.scheduled_days)
    local minimum, maximum = 1, math.max(1, config.maximum_review_interval)

    local function interval_of(raw)
        local value, lower, upper = States.constrain(
            raw * config.interval_multiplier, minimum, maximum, true)
        return {
            kind = "review",
            scheduled_days = math.floor(raw * config.interval_multiplier + 0.5),
            fuzz_lower = lower,
            fuzz_upper = upper,
            ease_factor = state.ease_factor,
            lapses = state.lapses,
        }
    end

    if which == "good" then
        local interval = interval_of((current_interval + days_late / 2) * state.ease_factor)
        interval.ease_factor = state.ease_factor
        return interval
    elseif which == "easy" then
        local interval = interval_of((current_interval + days_late) * state.ease_factor * config.easy_multiplier)
        interval.ease_factor = state.ease_factor + EASE_EASY
        return interval
    elseif which == "hard" then
        local raw = current_interval * config.hard_multiplier
        local interval = interval_of(raw)
        interval.ease_factor = math.max(MIN_EASE, state.ease_factor + EASE_HARD)
        return interval
    end

    -- again: lapse
    local lapse_interval = math.max(
        current_interval * config.lapse_multiplier,
        config.minimum_lapse_interval)
    local value, lower, upper = States.constrain(
        lapse_interval, minimum, maximum, true)
    local relearn_steps = Steps.new(config.relearn_steps)
    local delay = relearn_steps:again_delay()
    local leeched = config.leech_threshold > 0
        and (state.lapses + 1) >= config.leech_threshold
    if delay then
        return {
            kind = "relearning",
            remaining_steps = relearn_steps:remaining_for_failed(),
            scheduled_secs = delay,
            review = {
                scheduled_days = math.floor(lapse_interval + 0.5),
                fuzz_lower = lower,
                fuzz_upper = upper,
                ease_factor = math.max(MIN_EASE, state.ease_factor + EASE_AGAIN),
                lapses = state.lapses + 1,
                leeched = leeched,
            },
        }
    end
    return {
        kind = "review",
        scheduled_days = math.floor(lapse_interval + 0.5),
        fuzz_lower = lower,
        fuzz_upper = upper,
        ease_factor = math.max(MIN_EASE, state.ease_factor + EASE_AGAIN),
        lapses = state.lapses + 1,
        leeched = leeched,
    }
end

local function relearning_answer(state, config, ctx, which)
    local steps = Steps.new(config.relearn_steps)
    local remaining = state.remaining_steps or #config.relearn_steps

    if which == "again" then
        local delay = steps:again_delay()
        if delay then
            return {
                kind = "relearning",
                remaining_steps = steps:remaining_for_failed(),
                scheduled_secs = delay,
                review = state.review,
            }
        end
    elseif which == "hard" then
        local delay = steps:hard_delay(remaining)
        if delay then
            return {
                kind = "relearning",
                remaining_steps = remaining,
                scheduled_secs = delay,
                review = state.review,
            }
        end
    elseif which == "good" then
        local delay = steps:good_delay(remaining)
        if delay then
            return {
                kind = "relearning",
                remaining_steps = steps:remaining_for_good(remaining),
                scheduled_secs = delay,
                review = state.review,
            }
        end
    end

    -- Graduating out of relearning restores the review state with the interval
    -- computed when the card lapsed.
    local review = state.review or { scheduled_days = 1, ease_factor = config.initial_ease, lapses = 0 }
    local interval = {
        kind = "review",
        scheduled_days = review.scheduled_days,
        fuzz_lower = review.fuzz_lower,
        fuzz_upper = review.fuzz_upper,
        ease_factor = review.ease_factor,
        lapses = review.lapses,
    }
    if which == "easy" then
        local minimum, maximum = 1, math.max(1, config.maximum_review_interval)
        local value, lower, upper = States.constrain(
            review.scheduled_days * config.easy_multiplier,
            minimum, maximum, true)
        interval.scheduled_days = review.scheduled_days
        interval.fuzz_lower = lower
        interval.fuzz_upper = upper
        interval.ease_factor = review.ease_factor + EASE_EASY
    end
    return interval
end

--- Four possible next states.  `current` mirrors the input state.
function States.next(state, config, ctx)
    ctx = ctx or {}
    local result = { current = state }
    local kind = state.kind

    if kind == "new" then
        local learning = {
            kind = "learning",
            remaining_steps = #(config.learn_steps or {}),
            scheduled_secs = 0,
        }
        result.current = state
        for _, which in ipairs({ "again", "hard", "good", "easy" }) do
            result[which] = learning_answer(learning, config, ctx, which)
        end
        return result
    end

    if kind == "learning" then
        for _, which in ipairs({ "again", "hard", "good", "easy" }) do
            result[which] = learning_answer(state, config, ctx, which)
        end
        return result
    end

    if kind == "review" then
        for _, which in ipairs({ "again", "hard", "good", "easy" }) do
            result[which] = review_answer(state, config, ctx, which)
        end
        return result
    end

    for _, which in ipairs({ "again", "hard", "good", "easy" }) do
        result[which] = relearning_answer(state, config, ctx, which)
    end
    return result
end

return States
