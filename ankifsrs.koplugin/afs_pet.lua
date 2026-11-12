-- Pet rules (pure Lua, no KOReader dependencies). Everything is derived from the review history, so nothing can
-- get out of sync: the same history always gives the same pet.
local Pet = {}

Pet.STAGE_NAMES = { [0] = "Egg", "Nibbler", "Muncher", "Gobbler" }
Pet.STAGE_FROM = { [0] = 0, 25, 250, 1000 }        -- growth (cards eaten) needed for each stage
Pet.MODES = { "gentle", "care", "hardcore" }
Pet.STARVE_DAYS = 5                                 -- hardcore: missed days in a row before the pet dies
Pet.WEAK_DAYS = 3                                   -- care/hardcore: missed days in a row before the pet looks weak
Pet.MAX_SHIELDS = 3

function Pet.stageFor(growth)
    local stage = 0
    for s = 0, 3 do if growth >= Pet.STAGE_FROM[s] then stage = s end end
    return stage
end

-- daily: { [day_index] = reviews done that day }, today: today's day index
-- opts: { goal = reviews per day, mode = "gentle"|"care"|"hardcore", hardcore_since = day index }
function Pet.compute(daily, today, opts)
    opts = opts or {}
    local goal = math.max(opts.goal or 20, 1)
    local mode = opts.mode or "gentle"
    local s = { goal = goal, mode = mode, streak = 0, best_streak = 0, shields = 0, missed_run = 0,
        lives_lost = 0, max_day = 0, hibernated = 0 }
    local first
    for idx in pairs(daily) do if not first or idx < first then first = idx end end

    local cum, base, hc_missed = 0, 0, 0     -- hc_missed: unprotected missed days since hardcore mode was switched on
    if first then
        for d = first, today - 1 do
            local c = daily[d] or 0
            cum = cum + c
            if c > s.max_day then s.max_day = c end
            if c >= goal then
                s.streak = s.streak + 1; s.missed_run = 0; hc_missed = 0
                if s.streak % 7 == 0 and s.shields < Pet.MAX_SHIELDS then s.shields = s.shields + 1 end
            elseif s.shields > 0 then
                s.shields = s.shields - 1; s.hibernated = s.hibernated + 1      -- the pet hibernates through the day
            else
                s.streak = 0; s.missed_run = s.missed_run + 1
                if opts.hardcore_since and d >= opts.hardcore_since then hc_missed = hc_missed + 1 end
            end
            if s.streak > s.best_streak then s.best_streak = s.streak end
            if mode == "hardcore" and hc_missed >= Pet.STARVE_DAYS then
                s.lives_lost = s.lives_lost + 1; s.last_death = d
                base = cum; s.missed_run = 0; s.streak = 0; hc_missed = 0
            end
        end
    end

    local c = daily[today] or 0
    cum = cum + c
    if c > s.max_day then s.max_day = c end
    s.today, s.total, s.growth = c, cum, cum - base
    s.fed_today = c >= goal
    s.streak_now = s.streak + (s.fed_today and 1 or 0)
    if s.streak_now > s.best_streak then s.best_streak = s.streak_now end
    s.stage = Pet.stageFor(s.growth)
    s.stage_name = Pet.STAGE_NAMES[s.stage]
    s.next_stage_at = Pet.STAGE_FROM[s.stage + 1]            -- nil at the top stage

    -- mood
    s.weak = false
    if s.last_death and s.last_death >= today - 2 and s.growth == 0 then
        s.mood = "tomb"
    elseif s.fed_today then
        s.mood = "full"
    elseif c > 0 then
        s.mood = "idle"
    elseif mode ~= "gentle" and s.missed_run >= Pet.WEAK_DAYS then
        s.mood, s.weak = "hungry", true
    elseif s.missed_run >= 1 then
        s.mood = "sleepy"
    else
        s.mood = "hungry"
    end
    return s
end

function Pet.sprite(state)
    if state.mood == "tomb" then return "tomb" end
    return string.format("s%d_%s", state.stage, state.mood)
end

local LINES = {
    full = { "%s is stuffed and happy. What a feast!", "Burp! %s thanks you for today's cards.", "%s is purring with a full belly." },
    idle = { "%s is munching away. A few more cards!", "Nom nom. %s wants to finish today's meal.", "%s is still hungry. Keep feeding it cards!" },
    hungry = { "%s is staring at you. Feed me cards!", "%s's tummy is rumbling.", "%s is waiting for the first card of the day." },
    sleepy = { "%s has been napping. A card might wake it up.", "Zzz… %s dreams of flashcards.", "%s curled up and waits for you, no rush." },
    weak = { "%s is looking thin. One good meal will bring it back.", "%s is weak with hunger. Feed it soon!" },
    tomb = { "%s starved. A new egg is waiting in the grass.", "%s is gone. A new egg has appeared." },
}

function Pet.message(state, name, seed)
    local key = state.weak and "weak" or state.mood
    local list = LINES[key] or LINES.idle
    return string.format(list[(seed or 0) % #list + 1], name)
end

-- Achievements, all derived from the history
function Pet.badges(state)
    local list = {
        { "First bite", state.total >= 1 },
        { "Hatched (25 cards)", state.total >= 25 },
        { "Snacker (100 cards)", state.total >= 100 },
        { "Muncher (500 cards)", state.total >= 500 },
        { "Gobbler (1,000 cards)", state.total >= 1000 },
        { "Legend (5,000 cards)", state.total >= 5000 },
        { "7-day streak", state.best_streak >= 7 },
        { "30-day streak", state.best_streak >= 30 },
        { "Feast: 50 cards in a day", state.max_day >= 50 },
    }
    local out = {}
    for _, b in ipairs(list) do out[#out + 1] = { text = b[1], earned = b[2] } end
    return out
end

function Pet.bar(n, total, width)
    width = width or 20
    local filled = total > 0 and math.min(width, math.floor(n / total * width + 0.5)) or 0
    return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
end

return Pet
