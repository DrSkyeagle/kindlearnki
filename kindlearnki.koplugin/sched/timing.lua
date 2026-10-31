-- Day boundaries, the way v3 computes them.
--
-- Source: rslib/src/scheduler/timing.rs:22-76 (sched_timing_today_v2_new).
-- The short version: convert both timestamps into *local* dates using the
-- offsets Anki stored, subtract the civil day numbers, and subtract one more
-- if today's rollover hour has not passed yet.
--
-- The v1 formula — floor((now - created) / 86400) — is deliberately not used:
-- it drifts across DST and timezone changes, and it is what made the old
-- plugin disagree with the desktop by a day now and then.

local Timing = {}

local function is_leap(year)
    return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
function Timing.days_from_civil(year, month, day)
    year = month <= 2 and year - 1 or year
    local era = math.floor(year / 400)
    local yoe = year - era * 400
    local mp = (month + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- UTC offset of the host timezone at `stamp`, in seconds east of UTC.
function Timing.utc_offset(stamp)
    local local_time = os.date("*t", stamp)
    local utc_time = os.date("!*t", stamp)
    local as_local = os.time(local_time)
    local as_utc = os.time(utc_time)
    return as_local - as_utc
end

--- Local calendar fields for `stamp` shifted by `offset` seconds.
-- @treturn number year, month, day, seconds_into_day
function Timing.local_fields(stamp, offset)
    local fields = os.date("!*t", stamp + (offset or 0))
    return fields.year, fields.month, fields.day,
        fields.hour * 3600 + fields.min * 60 + fields.sec
end

--- The v3 `days_elapsed` for a collection.
--
-- @tparam table opts
--   created          UNIX seconds of col.crt
--   created_offset   seconds east, from config creationOffset (minutes west)
--   now              UNIX seconds
--   now_offset       seconds east for `now`
--   rollover_hour    config `rollover` (4 in this collection)
-- @treturn number days, number next_day_at
function Timing.days_elapsed(opts)
    local cy, cm, cd = Timing.local_fields(opts.created, opts.created_offset or 0)
    local ny, nm, nd, seconds_today =
        Timing.local_fields(opts.now, opts.now_offset or 0)

    local days = Timing.days_from_civil(ny, nm, nd)
        - Timing.days_from_civil(cy, cm, cd)

    local rollover_hour = opts.rollover_hour or 4
    local passed = seconds_today >= rollover_hour * 3600
    if not passed then
        days = days - 1
    end
    if days < 0 then
        days = 0
    end

    -- Next rollover, used by the UI to say "明天 4 点重置".
    local seconds_to_rollover = rollover_hour * 3600 - seconds_today
    if seconds_to_rollover <= 0 then
        seconds_to_rollover = seconds_to_rollover + 86400
    end
    return days, opts.now + seconds_to_rollover
end

--- Minutes-west (Anki's sign convention) to seconds-east.
function Timing.minutes_west_to_offset_seconds(minutes_west)
    return -(minutes_west or 0) * 60
end

Timing.is_leap = is_leap
Timing.MONTH_DAYS = MONTH_DAYS

return Timing
