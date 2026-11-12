-- SQLite persistence for decks, notes, cards (with FSRS state) and the review log.
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local Store = {}
Store.__index = Store

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS decks(id INTEGER PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE IF NOT EXISTS deck_opts(name TEXT PRIMARY KEY, new_limit INTEGER DEFAULT -1, rev_limit INTEGER DEFAULT -1, retention REAL DEFAULT -1);
CREATE TABLE IF NOT EXISTS models(mid INTEGER PRIMARY KEY, name TEXT, kind INTEGER, fields TEXT, tmpls TEXT, css TEXT);
CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, guid TEXT UNIQUE, mid INTEGER, flds TEXT, tags TEXT);
CREATE TABLE IF NOT EXISTS cards(id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER,
  state INTEGER DEFAULT 0, step INTEGER DEFAULT 0, due INTEGER DEFAULT 0, stability REAL, difficulty REAL,
  last_review INTEGER, reps INTEGER DEFAULT 0, lapses INTEGER DEFAULT 0, suspended INTEGER DEFAULT 0,
  pos INTEGER DEFAULT 0, leech INTEGER DEFAULT 0, buried_until INTEGER DEFAULT 0, UNIQUE(nid, ord));
CREATE INDEX IF NOT EXISTS idx_cards_q ON cards(did, state, due);
CREATE TABLE IF NOT EXISTS revlog(id INTEGER PRIMARY KEY AUTOINCREMENT, cid INTEGER, ts INTEGER, rating INTEGER,
  state INTEGER, elapsed REAL, stability REAL, difficulty REAL, ivl INTEGER, first INTEGER, secs REAL DEFAULT 0, imported INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_revlog_ts ON revlog(ts);
CREATE TABLE IF NOT EXISTS media(name TEXT PRIMARY KEY, file TEXT);
]]

local MIGRATIONS = {
    "ALTER TABLE cards ADD COLUMN leech INTEGER DEFAULT 0",
    "ALTER TABLE cards ADD COLUMN buried_until INTEGER DEFAULT 0",
    "ALTER TABLE revlog ADD COLUMN secs REAL DEFAULT 0",
    "ALTER TABLE deck_opts ADD COLUMN retention REAL DEFAULT -1",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_revlog_cid_ts ON revlog(cid, ts)",
}

local function num(v) if type(v) == "cdata" then return tonumber(v) end return v end

function Store.open(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local self = setmetatable({}, Store)
    self.conn = SQ3.open(path)
    self.conn:exec(SCHEMA)
    for _, sql in ipairs(MIGRATIONS) do pcall(self.conn.exec, self.conn, sql) end   -- no-ops on up-to-date databases
    -- reviews imported from Anki packages are flagged so the pet only counts reviews done on this device.
    -- Rows that were imported before the flag existed are recognised by their empty memory state.
    if pcall(self.conn.exec, self.conn, "ALTER TABLE revlog ADD COLUMN imported INTEGER DEFAULT 0") then
        pcall(self.conn.exec, self.conn, "UPDATE revlog SET imported = 1 WHERE first = 0 AND stability = 0 AND difficulty = 0")
    end
    return self
end

function Store:close() if self.conn then self.conn:close(); self.conn = nil end end

-- Returns an array of rows (arrays); int64 cdata converted to Lua numbers.
-- NOTE: exec() splits statements on ';', so never put user data inside SQL text - use get/getRow/queryBound/run.
function Store:query(sql)
    local res = self.conn:exec(sql)
    local rows = {}
    if not res then return rows end
    local ncol, nrow = #res, 0
    for c = 1, ncol do if #res[c] > nrow then nrow = #res[c] end end
    for r = 1, nrow do
        local row = {}
        for c = 1, ncol do row[c] = num(res[c][r]) end
        rows[r] = row
    end
    return rows
end

function Store:scalar(sql)
    local r = self:query(sql)[1]
    return r and r[1]
end

function Store:exec(sql) return self.conn:exec(sql) end

local function copy_row(row)
    local o = {}
    for k, v in pairs(row) do if type(k) == "number" then o[k] = num(v) end end
    return o
end

-- Bound-parameter helpers (safe for any characters in the values)
function Store:getRow(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:reset():bind(...)
    local row = stmt:step()
    local out = row and copy_row(row) or nil
    stmt:close()
    return out
end

function Store:get(sql, ...)
    local r = self:getRow(sql, ...)
    return r and r[1]
end

function Store:queryBound(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:reset():bind(...)
    local out = {}
    while true do
        local row = stmt:step()
        if not row then break end
        out[#out + 1] = copy_row(row)
    end
    stmt:close()
    return out
end

function Store:run(sql, ...)
    local stmt = self.conn:prepare(sql)
    stmt:reset():bind(...):step()
    stmt:close()
end

function Store:begin() self.conn:exec("BEGIN") end
function Store:commit() self.conn:exec("COMMIT") end

-- Decks ------------------------------------------------------------------------
function Store:deckId(name)
    local id = self:get("SELECT id FROM decks WHERE name = ?", name)
    if id then return id end
    self:run("INSERT INTO decks(name) VALUES(?)", name)
    return self:get("SELECT id FROM decks WHERE name = ?", name)
end

function Store:deckNames()
    local out = {}
    for _, r in ipairs(self:query("SELECT name FROM decks ORDER BY name")) do out[#out + 1] = r[1] end
    return out
end

-- ids of a deck and all of its sub-decks ("A" matches "A" and "A::B")
function Store:deckIds(name)
    local ids = {}
    for _, r in ipairs(self:query("SELECT id, name FROM decks")) do
        if not name or r[2] == name or r[2]:sub(1, #name + 2) == name .. "::" then ids[#ids + 1] = r[1] end
    end
    return ids
end

-- Per-deck options; every field is nil when it is not set for this deck (meaning: inherit / use the global value)
function Store:deckOpts(name)
    local r = name and self:getRow("SELECT new_limit, rev_limit, retention FROM deck_opts WHERE name = ?", name)
    if not r then return {} end
    return { new = (r[1] and r[1] >= 0) and r[1] or nil, rev = (r[2] and r[2] >= 0) and r[2] or nil,
        retention = (r[3] and r[3] > 0) and r[3] or nil }
end

local OPT_COLUMNS = { new = "new_limit", rev = "rev_limit", retention = "retention" }

function Store:setDeckOpt(name, key, value)
    local col = OPT_COLUMNS[key]
    if not col then return end
    self:run("INSERT OR IGNORE INTO deck_opts(name) VALUES(?)", name)
    self:run("UPDATE deck_opts SET " .. col .. " = ? WHERE name = ?", value or -1, name)
    local o = self:deckOpts(name)
    if not o.new and not o.rev and not o.retention then self:run("DELETE FROM deck_opts WHERE name = ?", name) end
end

function Store:clearDeckOpts(name) self:run("DELETE FROM deck_opts WHERE name = ?", name) end

function Store:deckLimits(name)
    local o = self:deckOpts(name)
    return o.new, o.rev
end

function Store:deckNameById(did) return self:get("SELECT name FROM decks WHERE id = ?", did) end

-- Queue / counts ---------------------------------------------------------------
local function in_list(ids)
    if #ids == 0 then return "(-1)" end
    return "(" .. table.concat(ids, ",") .. ")"
end
Store.in_list = in_list

function Store:newToday(ids, day_start)
    return self:scalar("SELECT COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.first = 1 AND r.ts >= "
        .. day_start .. " AND c.did IN " .. in_list(ids)) or 0
end

function Store:reviewsToday(ids, day_start)
    return self:scalar("SELECT COUNT(*) FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.first = 0 AND r.state = 2 AND r.ts >= "
        .. day_start .. " AND c.did IN " .. in_list(ids)) or 0
end

function Store:counts(ids, now, day_end, day_start, new_limit, rev_limit, learn_ahead)
    local base = "SELECT COUNT(*) FROM cards WHERE suspended = 0 AND buried_until <= " .. now .. " AND did IN " .. in_list(ids)
    local learn = self:scalar(base .. " AND state IN (1,3) AND due <= " .. (now + learn_ahead)) or 0
    local rev = self:scalar(base .. " AND state = 2 AND due < " .. day_end) or 0
    local new = self:scalar(base .. " AND state = 0") or 0
    local new_left = math.max(0, new_limit - self:newToday(ids, day_start))
    local rev_left = math.max(0, rev_limit - self:reviewsToday(ids, day_start))
    return math.min(new, new_left), learn, math.min(rev, rev_left)
end

local CARD_COLS = "c.id, c.nid, c.did, c.ord, c.state, c.step, c.due, c.stability, c.difficulty, c.last_review, c.reps, c.lapses, c.leech, c.suspended, c.buried_until"
local function row_to_card(r)
    if not r then return nil end
    return { id = r[1], nid = r[2], did = r[3], ord = r[4], state = r[5], step = r[6], due = r[7],
        stability = r[8], difficulty = r[9], last_review = r[10], reps = r[11], lapses = r[12],
        leech = r[13], suspended = r[14], buried_until = r[15] }
end

local REVIEW_ORDER = {
    due = "c.due, c.id",
    random = "RANDOM()",
}

-- Next card: due learning -> reviews -> new cards (within daily limits), then learn-ahead cards.
-- opts = { review_order = "due"|"random"|"overdue", new_order = "pos"|"random" }
function Store:nextCard(ids, now, day_end, day_start, new_limit, rev_limit, learn_ahead, opts)
    opts = opts or {}
    local base = "SELECT " .. CARD_COLS .. " FROM cards c WHERE c.suspended = 0 AND c.buried_until <= " .. now
        .. " AND c.did IN " .. in_list(ids)
    local r = self:query(base .. " AND c.state IN (1,3) AND c.due <= " .. now .. " ORDER BY c.due LIMIT 1")[1]
    if r then return row_to_card(r) end
    if self:reviewsToday(ids, day_start) < rev_limit then
        local order = REVIEW_ORDER[opts.review_order or "due"]
        if opts.review_order == "overdue" then
            order = "(" .. now .. " - c.due) * 1.0 / MAX(c.due - IFNULL(c.last_review, 0), 86400) DESC, c.id"
        end
        r = self:query(base .. " AND c.state = 2 AND c.due < " .. day_end .. " ORDER BY " .. (order or "c.due, c.id") .. " LIMIT 1")[1]
        if r then return row_to_card(r) end
    end
    if self:newToday(ids, day_start) < new_limit then
        local order = (opts.new_order == "random") and "RANDOM()" or "c.pos, c.id"
        r = self:query(base .. " AND c.state = 0 ORDER BY " .. order .. " LIMIT 1")[1]
        if r then return row_to_card(r) end
    end
    r = self:query(base .. " AND c.state IN (1,3) AND c.due <= " .. (now + learn_ahead) .. " ORDER BY c.due LIMIT 1")[1]
    return row_to_card(r)
end

function Store:cardById(id)
    return row_to_card(self:query("SELECT " .. CARD_COLS .. " FROM cards c WHERE c.id = " .. id)[1])
end

-- Everything needed to render a card
function Store:cardContent(card)
    local n = self:query("SELECT guid, mid, flds, tags FROM notes WHERE id = " .. card.nid)[1]
    if not n then return nil end
    local m = self:query("SELECT name, kind, fields, tmpls, css FROM models WHERE mid = " .. n[2])[1]
    local d = self:scalar("SELECT name FROM decks WHERE id = " .. card.did) or ""
    return { guid = n[1], mid = n[2], flds = n[3], tags = n[4], model = m, deck = d }
end

function Store:mediaFile(name)
    return self:get("SELECT file FROM media WHERE name = ?", name)
end

-- Persist the result of answering a card. `res` comes from FSRS:answer. Returns the revlog id.
function Store:saveAnswer(card, res, rating, now, rollover, secs)
    local first = (card.state == 0) and 1 or 0
    local elapsed = (card.last_review and card.last_review > 0) and (now - card.last_review) / 86400 or 0
    self:run([[INSERT INTO revlog(cid, ts, rating, state, elapsed, stability, difficulty, ivl, first, secs)
        VALUES(?,?,?,?,?,?,?,?,?,?)]], card.id, now, rating, card.state, elapsed, card.stability or 0, card.difficulty or 0,
        res.interval_days or 0, first, secs or 0)
    local lapses = card.lapses + ((card.state == 2 and rating == 1) and 1 or 0)
    self:run([[UPDATE cards SET state=?, step=?, due=?, stability=?, difficulty=?, last_review=?, reps=?, lapses=?
        WHERE id=?]], res.state, res.step, res.due, res.stability, res.difficulty, now, card.reps + 1, lapses, card.id)
    return self:scalar("SELECT MAX(id) FROM revlog"), lapses
end

function Store:undo(entry)
    local c = entry.card
    self:run("DELETE FROM revlog WHERE id = ?", entry.revlog_id)
    self:run([[UPDATE cards SET state=?, step=?, due=?, stability=?, difficulty=?, last_review=?, reps=?, lapses=?,
        leech=?, suspended=? WHERE id=?]], c.state, c.step, c.due, c.stability or 0, c.difficulty or 0, c.last_review or 0,
        c.reps, c.lapses, c.leech or 0, c.suspended or 0, c.id)
    if entry.buried_ids and #entry.buried_ids > 0 then self:unbury(entry.buried_ids) end
end

function Store:setSuspended(id, v) self:run("UPDATE cards SET suspended = ? WHERE id = ?", v and 1 or 0, id) end

function Store:markLeech(id) self:run("UPDATE cards SET leech = 1, suspended = 1 WHERE id = ?", id) end

function Store:bury(ids, until_ts)
    if #ids == 0 then return end
    self:exec("UPDATE cards SET buried_until = " .. math.floor(until_ts) .. " WHERE id IN " .. in_list(ids))
end

function Store:unbury(ids)
    if #ids == 0 then return end
    self:exec("UPDATE cards SET buried_until = 0 WHERE id IN " .. in_list(ids))
end

-- other cards of the same note that are free to be buried right now
function Store:siblingIds(nid, cid, now)
    local ids = {}
    for _, r in ipairs(self:query("SELECT id FROM cards WHERE nid = " .. nid .. " AND id <> " .. cid
        .. " AND suspended = 0 AND state IN (0,2) AND buried_until <= " .. now)) do ids[#ids + 1] = r[1] end
    return ids
end

-- "Forget": make the card new again
function Store:forget(id)
    self:run([[UPDATE cards SET state=0, step=0, due=0, stability=0, difficulty=0, last_review=0, reps=0, leech=0,
        suspended=0, buried_until=0, pos=(SELECT IFNULL(MAX(pos),0)+1 FROM cards) WHERE id=?]], id)
end

function Store:noteFields(nid)
    local r = self:getRow("SELECT flds, mid FROM notes WHERE id = ?", nid)
    if not r then return nil end
    return r[1], r[2]
end

function Store:updateNoteFields(nid, flds) self:run("UPDATE notes SET flds = ? WHERE id = ?", flds, nid) end

-- Statistics -------------------------------------------------------------------
function Store:cardTotals()
    local s = {}
    local function c(where) return self:scalar("SELECT COUNT(*) FROM cards WHERE " .. where) or 0 end
    s.total, s.new, s.learning = c("1=1"), c("state = 0 AND suspended = 0"), c("state IN (1,3) AND suspended = 0")
    s.review, s.suspended, s.leeches = c("state = 2 AND suspended = 0"), c("suspended = 1"), c("leech = 1")
    s.mature = c("state = 2 AND stability >= 21")
    return s
end

function Store:reviewCount(since) return self:scalar("SELECT COUNT(*) FROM revlog WHERE ts >= " .. math.floor(since)) or 0 end

-- % of review-state answers that were not "Again" since `since`
function Store:retention(since)
    local seen = self:scalar("SELECT COUNT(*) FROM revlog WHERE state = 2 AND ts >= " .. math.floor(since)) or 0
    if seen == 0 then return nil, 0 end
    local passed = self:scalar("SELECT COUNT(*) FROM revlog WHERE state = 2 AND rating > 1 AND ts >= " .. math.floor(since)) or 0
    return 100 * passed / seen, seen
end

function Store:avgSecs(since)
    local r = self:query("SELECT AVG(secs), COUNT(*) FROM revlog WHERE secs > 0 AND ts >= " .. math.floor(since))[1]
    if not r or not r[1] then return nil end
    return r[1], r[2]
end

-- {[0]=today(+overdue+learning), [1]=tomorrow, ...} up to `days`
function Store:forecast(day_start, days)
    local out = {}
    for d = 0, days do out[d] = 0 end
    for _, r in ipairs(self:query("SELECT CASE WHEN due < " .. (day_start + 86400) .. " THEN 0 ELSE CAST((due - " .. day_start
        .. ") / 86400 AS INTEGER) END AS d, COUNT(*) FROM cards WHERE state = 2 AND suspended = 0 GROUP BY d")) do
        if r[1] <= days then out[r[1]] = out[r[1]] + r[2] end
    end
    out[0] = out[0] + (self:scalar("SELECT COUNT(*) FROM cards WHERE state IN (1,3) AND suspended = 0") or 0)
    return out
end

-- consecutive study days ending today (or yesterday), and total days studied
function Store:streak(phase, today_idx)
    local have = {}
    local total = 0
    for _, r in ipairs(self:query("SELECT DISTINCT (ts - " .. math.floor(phase) .. ") / 86400 FROM revlog")) do
        have[r[1]] = true; total = total + 1
    end
    local d = have[today_idx] and today_idx or today_idx - 1
    local n = 0
    while have[d] do n = n + 1; d = d - 1 end
    return n, total
end

-- Reviews done on this device per study day: { [day_index] = count }
function Store:dailyCounts(phase)
    local out = {}
    for _, r in ipairs(self:query("SELECT (ts - " .. math.floor(phase) .. ") / 86400 AS d, COUNT(*) FROM revlog WHERE imported = 0 GROUP BY d")) do
        out[r[1]] = r[2]
    end
    return out
end

-- Card ids in a deck (and sub-decks) in the order the deck was authored, optionally filtered
function Store:cardIds(ids, where, order, limit)
    local sql = "SELECT c.id FROM cards c WHERE c.did IN " .. in_list(ids)
    if where then sql = sql .. " AND (" .. where .. ")" end
    sql = sql .. " ORDER BY " .. (order or "c.nid, c.ord")
    if limit then sql = sql .. " LIMIT " .. math.floor(limit) end
    local out = {}
    for i, r in ipairs(self:query(sql)) do out[i] = r[1] end
    return out
end

-- Browsing -----------------------------------------------------------------------
local BROWSE_COLS = "c.id, c.nid, c.ord, c.state, c.lapses, c.stability, c.difficulty, c.last_review, c.due, c.reps, c.leech, c.suspended, c.buried_until, n.flds"
local function info_row(r)
    return { id = r[1], nid = r[2], ord = r[3], state = r[4], lapses = r[5] or 0, stability = r[6] or 0, difficulty = r[7] or 0,
        last_review = r[8] or 0, due = r[9] or 0, reps = r[10] or 0, leech = r[11] or 0, suspended = r[12] or 0,
        buried = r[13] or 0, flds = r[14] or "" }
end

local BROWSE_FROM = " FROM cards c JOIN notes n ON n.id = c.nid WHERE c.did IN "

function Store:browse(ids, where, order, limit)
    local sql = "SELECT " .. BROWSE_COLS .. BROWSE_FROM .. in_list(ids)
    if where then sql = sql .. " AND (" .. where .. ")" end
    if order then sql = sql .. " ORDER BY " .. order end
    sql = sql .. " LIMIT " .. (limit or 200)
    local out = {}
    for i, r in ipairs(self:query(sql)) do out[i] = info_row(r) end
    return out
end

function Store:browseSearch(ids, term, limit)
    local out = {}
    for i, r in ipairs(self:queryBound("SELECT " .. BROWSE_COLS .. BROWSE_FROM .. in_list(ids)
        .. " AND n.flds LIKE ? ORDER BY c.id LIMIT " .. (limit or 200), "%" .. term .. "%")) do out[i] = info_row(r) end
    return out
end

function Store:browseSlowest(ids, limit)
    local out = {}
    for _, r in ipairs(self:query("SELECT " .. BROWSE_COLS .. ", AVG(r.secs) FROM revlog r JOIN cards c ON c.id = r.cid JOIN notes n ON n.id = c.nid"
        .. " WHERE c.did IN " .. in_list(ids) .. " AND r.secs > 0 GROUP BY c.id HAVING COUNT(*) >= 2 ORDER BY AVG(r.secs) DESC LIMIT " .. (limit or 200))) do
        local info = info_row(r); info.avg_secs = r[15]; out[#out + 1] = info
    end
    return out
end

function Store:cardInfo(id)
    local r = self:query("SELECT " .. BROWSE_COLS .. BROWSE_FROM .. "(SELECT did FROM cards WHERE id = " .. id .. ") AND c.id = " .. id)[1]
    if not r then return nil end
    local info = info_row(r)
    info.avg_secs = self:scalar("SELECT AVG(secs) FROM revlog WHERE secs > 0 AND cid = " .. id)
    return info
end

-- Review history for the optimiser
function Store:revlogRows()
    return self:query("SELECT cid, ts, rating FROM revlog WHERE rating BETWEEN 1 AND 4 ORDER BY cid, ts")
end

-- Review log as JSON lines keyed by note guid + card ordinal (for merging back on a PC)
function Store:exportRevlog(JSON, path)
    local f = io.open(path, "w")
    if not f then return nil end
    local n = 0
    for _, r in ipairs(self:query([[SELECT n.guid, c.ord, r.ts, r.rating, r.state, r.stability, r.difficulty, r.ivl, r.secs
        FROM revlog r JOIN cards c ON c.id = r.cid JOIN notes n ON n.id = c.nid ORDER BY r.ts]])) do
        f:write(JSON.encode({ guid = r[1], ord = r[2], ts = r[3], rating = r[4], state = r[5],
            stability = r[6], difficulty = r[7], ivl = r[8], secs = r[9] }), "\n")
        n = n + 1
    end
    f:close()
    return n
end

return Store
