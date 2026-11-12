-- On-device FSRS-6 parameter fitting (derivative-free coordinate search with regularisation to the
-- defaults and a held-out validation split). Pure Lua; no KOReader dependencies.
local FSRS = require("afs_fsrs")

local Opt = {}
Opt.__index = Opt

local exp, log, floor = math.exp, math.log, math.floor
local S_MIN, S_MAX = 0.001, 36500

-- hard bounds per parameter (same ranges the reference optimiser clamps to)
local LO = { 0.001, 0.001, 0.001, 0.001, 1, 0.001, 0.001, 0.001, 0, 0, 0.001, 0.001, 0.001, 0.001, 0, 0, 1, 0, 0, 0, 0.1 }
local HI = { 100, 100, 100, 100, 10, 4, 4, 0.75, 4.5, 0.8, 3.5, 5, 0.25, 0.9, 4, 1, 6, 2, 2, 0.8, 0.8 }

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end

-- rows: list of {cid, ts, rating} ordered by cid then ts. phase: seconds offset of the day boundary.
-- Returns a list of sequences { cid = n, [i] = { dt = whole days since previous review, g = rating } }.
function Opt.buildSequences(rows, phase)
    local seqs, cur, last_cid, last_day = {}, nil, nil, nil
    for _, r in ipairs(rows) do
        local cid, ts, g = r[1], r[2], r[3]
        if g >= 1 and g <= 4 then
            local day = floor((ts - phase) / 86400)
            if cid ~= last_cid then
                cur = { cid = cid }; seqs[#seqs + 1] = cur
                last_cid = cid
                cur[1] = { dt = 0, g = g }
            else
                cur[#cur + 1] = { dt = math.max(day - last_day, 0), g = g }
            end
            last_day = day
        end
    end
    return seqs
end

-- Mean log-loss over reviews that happened >= 1 day after the previous review.
local function evaluate(seqs, w)
    local decay = -w[21]
    local factor = 0.9 ^ (1 / decay) - 1
    local d0_easy = w[5] - exp(w[6] * 3) + 1
    local loss, n = 0, 0
    for _, seq in ipairs(seqs) do
        local s, d
        for i = 1, #seq do
            local ev = seq[i]
            local g = ev.g
            if i == 1 then
                s = math.max(w[g], S_MIN)
                d = clamp(w[5] - exp(w[6] * (g - 1)) + 1, 1, 10)
            else
                if ev.dt < 1 then
                    local inc = exp(w[18] * (g - 3 + w[19])) * (s ^ -w[20])
                    if g >= 3 and inc < 1 then inc = 1 end
                    s = clamp(s * inc, S_MIN, S_MAX)
                else
                    local r = (1 + factor * ev.dt / s) ^ decay
                    r = clamp(r, 1e-5, 1 - 1e-5)
                    if g > 1 then loss = loss - log(r) else loss = loss - log(1 - r) end
                    n = n + 1
                    if g == 1 then
                        local long = w[12] * (d ^ -w[13]) * (((s + 1) ^ w[14]) - 1) * exp((1 - r) * w[15])
                        local short = s / exp(w[18] * w[19])
                        s = math.min(long, short)
                    else
                        local hard = (g == 2) and w[16] or 1
                        local easy = (g == 4) and w[17] or 1
                        s = s * (1 + exp(w[9]) * (11 - d) * (s ^ -w[10]) * (exp((1 - r) * w[11]) - 1) * hard * easy)
                    end
                    s = clamp(s, S_MIN, S_MAX)
                end
                local nd = d - w[7] * (g - 3) * (10 - d) / 9
                d = clamp(w[8] * d0_easy + (1 - w[8]) * nd, 1, 10)
            end
        end
    end
    return n > 0 and loss / n or 0, n
end
Opt.evaluate = evaluate

function Opt.new(seqs, w0)
    local self = setmetatable({}, Opt)
    self.train, self.test = {}, {}
    for _, q in ipairs(seqs) do
        if q.cid % 5 == 0 then self.test[#self.test + 1] = q else self.train[#self.train + 1] = q end
    end
    if #self.test < 20 then self.train, self.test = seqs, seqs end   -- tiny data: no hold-out
    self.w0 = {}; self.w = {}
    for i = 1, 21 do self.w0[i] = w0[i]; self.w[i] = clamp(w0[i], LO[i], HI[i]) end
    local _, n = evaluate(self.train, self.w)
    self.n_train = n
    self.lambda = 30 / math.max(n, 1)
    self.frac, self.pass, self.idx = 0.15, 0, 1
    self.best = self:objective(self.w)
    self.start_train = evaluate(self.train, self.w)
    self.start_test = evaluate(self.test, self.w0)
    self.done = false
    return self
end

function Opt:objective(w)
    local l = evaluate(self.train, w)
    local reg = 0
    for i = 1, 21 do local z = (w[i] - self.w0[i]) / (HI[i] - LO[i]); reg = reg + z * z end
    return l + 0.5 * self.lambda * reg
end

-- Run for about `budget` seconds of CPU time. Returns true when finished.
function Opt:run(budget)
    local t0 = os.clock()
    while not self.done and os.clock() - t0 < budget do
        local i = self.idx
        local step = (HI[i] - LO[i]) * self.frac
        local improved = false
        for _, dir in ipairs({ 1, -1 }) do
            local old = self.w[i]
            local nv = clamp(old + dir * step, LO[i], HI[i])
            if nv ~= old then
                self.w[i] = nv
                local o = self:objective(self.w)
                if o < self.best - 1e-9 then self.best = o; improved = true; break end
                self.w[i] = old
            end
        end
        if improved then self.any = true end
        self.idx = i + 1
        if self.idx > 21 then
            self.idx = 1; self.pass = self.pass + 1
            if not self.any then self.frac = self.frac / 2 end
            self.any = false
            if self.frac < 0.004 or self.pass >= 60 then self.done = true end
        end
    end
    return self.done
end

-- Summary of the result for the confirmation dialog.
function Opt:result()
    local after_test = evaluate(self.test, self.w)
    local after_train = evaluate(self.train, self.w)
    local _, n_test = evaluate(self.test, self.w)
    return { w = self.w, test_before = self.start_test, test_after = after_test,
        train_before = self.start_train, train_after = after_train, n_train = self.n_train, n_test = n_test,
        better = after_test < self.start_test - 1e-4 }
end

-- number of reviews usable for fitting (>= 1 day after the previous review)
function Opt.countLong(seqs)
    local n = 0
    for _, q in ipairs(seqs) do for i = 2, #q do if q[i].dt >= 1 then n = n + 1 end end end
    return n
end

return Opt
