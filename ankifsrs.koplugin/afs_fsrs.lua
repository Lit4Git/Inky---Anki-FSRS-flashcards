-- FSRS-6 scheduler (port of the reference py-fsrs / fsrs-rs formulas).
-- Pure Lua, no KOReader dependencies, works on LuaJIT and Lua 5.x.

local FSRS = {}

FSRS.DEFAULT_W = {
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722,
    0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
    0.0912, 0.0658, 0.1542,
}

-- States
FSRS.NEW, FSRS.LEARNING, FSRS.REVIEW, FSRS.RELEARNING = 0, 1, 2, 3
-- Ratings
FSRS.AGAIN, FSRS.HARD, FSRS.GOOD, FSRS.EASY = 1, 2, 3, 4

local S_MIN = 0.001
local exp, floor = math.exp, math.floor

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- Accept 21 (FSRS-6) or 19 (FSRS-5) parameters; FSRS-5 is upgraded like fsrs-rs does.
function FSRS.normalizeParams(w)
    if type(w) ~= "table" then return nil, "no parameters" end
    local out = {}
    for i, v in ipairs(w) do
        if type(v) ~= "number" or v ~= v then return nil, "bad number" end
        out[i] = v
    end
    if #out == 19 then out[20] = 0.0; out[21] = 0.5 end
    if #out ~= 21 then return nil, "need 19 or 21 parameters, got " .. #w end
    return out
end

function FSRS.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = FSRS })
    self.w = FSRS.normalizeParams(opts.w or FSRS.DEFAULT_W)
    self.retention = opts.retention or 0.9
    self.max_ivl = opts.max_interval or 36500
    self.learning_steps = opts.learning_steps or { 1, 10 }      -- minutes
    self.relearning_steps = opts.relearning_steps or { 10 }     -- minutes
    self.decay = -self.w[21]
    self.factor = 0.9 ^ (1 / self.decay) - 1
    return self
end

-- Probability of recall after t days with stability s
function FSRS:retrievability(t, s)
    if not s or s <= 0 then return 0 end
    return (1 + self.factor * t / s) ^ self.decay
end

function FSRS:nextInterval(s)
    local ivl = (s / self.factor) * (self.retention ^ (1 / self.decay) - 1)
    return clamp(floor(ivl + 0.5), 1, self.max_ivl)
end

function FSRS:initStability(g) return math.max(self.w[g], S_MIN) end

function FSRS:initDifficulty(g, no_clamp)
    local d = self.w[5] - exp(self.w[6] * (g - 1)) + 1
    if no_clamp then return d end
    return clamp(d, 1, 10)
end

function FSRS:nextDifficulty(d, g)
    local w = self.w
    local delta = -w[7] * (g - 3)
    local damped = d + delta * (10 - d) / 9
    local nd = w[8] * self:initDifficulty(4, true) + (1 - w[8]) * damped
    return clamp(nd, 1, 10)
end

function FSRS:shortTermStability(s, g)
    local w = self.w
    local inc = exp(w[18] * (g - 3 + w[19])) * (s ^ -w[20])
    if g >= 3 then inc = math.max(inc, 1.0) end
    return math.max(s * inc, S_MIN)
end

function FSRS:nextRecallStability(d, s, r, g)
    local w = self.w
    local hard = (g == 2) and w[16] or 1
    local easy = (g == 4) and w[17] or 1
    return math.max(s * (1 + exp(w[9]) * (11 - d) * (s ^ -w[10])
        * (exp((1 - r) * w[11]) - 1) * hard * easy), S_MIN)
end

function FSRS:nextForgetStability(d, s, r)
    local w = self.w
    local long = w[12] * (d ^ -w[13]) * (((s + 1) ^ w[14]) - 1) * exp((1 - r) * w[15])
    local short = s / exp(w[18] * w[19])
    return math.max(math.min(long, short), S_MIN)
end

-- Anki's "day" boundary handling -------------------------------------------------
-- rollover: hour of day at which the new study day starts (Anki default is 4)
function FSRS.dayStart(ts, rollover)
    rollover = rollover or 4
    local t = os.date("*t", ts - rollover * 3600)
    t.hour, t.min, t.sec, t.isdst = rollover, 0, 0, nil
    return os.time(t)
end

function FSRS.dayOffset(ts, n, rollover)
    rollover = rollover or 4
    local t = os.date("*t", ts - rollover * 3600)
    t.day = t.day + n
    t.hour, t.min, t.sec, t.isdst = rollover, 0, 0, nil
    return os.time(t)
end

function FSRS.daysBetween(from_ts, to_ts, rollover)
    local a, b = FSRS.dayStart(from_ts, rollover), FSRS.dayStart(to_ts, rollover)
    return floor((b - a) / 86400 + 0.5)
end

-- Core: compute the result of answering `card` with `rating` at time `now`.
-- card = { state, step, stability, difficulty, last_review }
-- returns a NEW table: { state, step, stability, difficulty, due, last_review, interval_days }
function FSRS:answer(card, rating, now, rollover)
    local w = self.w
    local c = {
        state = card.state or 0, step = card.step or 0,
        stability = card.stability, difficulty = card.difficulty,
        last_review = now,
    }
    local s, d = card.stability, card.difficulty
    local state = card.state or 0

    -- 1) update memory state
    if state == 0 or not s or not d or s <= 0 then
        s, d = self:initStability(rating), self:initDifficulty(rating)
    else
        local elapsed = (card.last_review and card.last_review > 0) and FSRS.daysBetween(card.last_review, now, rollover) or 0
        if elapsed < 1 then
            s = self:shortTermStability(s, rating)
        else
            local r = self:retrievability(elapsed, s)
            if rating == 1 then s = self:nextForgetStability(d, s, r)
            else s = self:nextRecallStability(d, s, r, rating) end
        end
        d = self:nextDifficulty(d, rating)
    end
    c.stability, c.difficulty = s, d

    -- 2) decide the next state / due time
    local function review_due()
        local ivl = self:nextInterval(s)
        c.state, c.step, c.interval_days = 2, 0, ivl
        c.due = FSRS.dayOffset(now, ivl, rollover)
    end
    local function in_minutes(m)
        c.due = now + math.floor(m * 60 + 0.5)
    end

    local function run_steps(steps, cur_state, cur_step)
        -- cur_step is 0-based index of the step the card is currently on
        if #steps == 0 or rating == 4 then return review_due() end
        c.state = cur_state
        if rating == 1 then
            c.step = 0; in_minutes(steps[1])
        elseif rating == 2 then
            c.step = cur_step
            local m
            if cur_step == 0 and #steps == 1 then m = steps[1] * 1.5
            elseif cur_step == 0 then m = (steps[1] + steps[2]) / 2
            else m = steps[cur_step + 1] end
            in_minutes(m)
        else -- good
            if cur_step + 1 >= #steps then return review_due() end
            c.step = cur_step + 1; in_minutes(steps[c.step + 1])
        end
    end

    if state == 0 or state == 1 then
        run_steps(self.learning_steps, 1, state == 0 and 0 or (card.step or 0))
    elseif state == 3 then
        run_steps(self.relearning_steps, 3, card.step or 0)
    else -- review
        if rating == 1 then
            if #self.relearning_steps == 0 then
                review_due()
            else
                c.state, c.step = 3, 0
                in_minutes(self.relearning_steps[1])
            end
        else
            review_due()
        end
    end
    if c.state == 2 and not c.interval_days then c.interval_days = self:nextInterval(s) end
    return c
end

-- Preview all four answers. Keeps Hard < Good < Easy for review intervals (like Anki).
function FSRS:preview(card, now, rollover)
    local res = {}
    for g = 1, 4 do res[g] = self:answer(card, g, now, rollover) end
    if res[2].state == 2 and res[3].state == 2 then
        local ivl = { res[2].interval_days, res[3].interval_days, res[4].state == 2 and res[4].interval_days or 0 }
        if ivl[2] <= ivl[1] and (card.state == 2 or card.state == 3) then ivl[2] = ivl[1] + 1 end
        if res[4].state == 2 and ivl[3] <= ivl[2] then ivl[3] = ivl[2] + 1 end
        if ivl[2] > self.max_ivl then ivl[2] = self.max_ivl end
        if ivl[3] > self.max_ivl then ivl[3] = self.max_ivl end
        for i, g in ipairs({ 3, 4 }) do
            local r = res[g]
            if r.state == 2 and r.interval_days ~= ivl[g - 1] then
                r.interval_days = ivl[g - 1]
                r.due = FSRS.dayOffset(now, r.interval_days, rollover)
            end
        end
        local r = res[2]
        if r.state == 2 and r.interval_days ~= ivl[1] then
            r.interval_days = ivl[1]; r.due = FSRS.dayOffset(now, r.interval_days, rollover)
        end
    end
    return res
end

-- Convert an Anki SM-2 card to an approximate FSRS memory state.
function FSRS.fromSM2(ivl_days, ease_permille)
    local d = 10 - ((ease_permille or 2500) - 1300) * 9 / 2200
    return math.max(ivl_days, 0.5), clamp(d, 1, 10)
end

-- Human friendly interval label for the answer buttons
function FSRS.label(seconds_from_now, due_is_day)
    local s = seconds_from_now
    if s < 3600 then return string.format("%dm", math.max(1, math.floor(s / 60 + 0.5))) end
    if s < 86400 and not due_is_day then return string.format("%dh", math.floor(s / 3600 + 0.5)) end
    local d = s / 86400
    if d < 30 then return string.format("%dd", math.max(1, math.floor(d + 0.5))) end
    if d < 365 then return string.format("%.1fmo", d / 30.4375) end
    return string.format("%.1fy", d / 365.25)
end

return FSRS
