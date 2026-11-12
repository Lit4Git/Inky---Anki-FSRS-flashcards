-- .apkg importer. Handles the legacy (.anki2 / .anki21) and the current (.anki21b, zstd + protobuf) formats.
local ffi = require("ffi")
local SQ3 = require("lua-ljsqlite3/init")
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local PB = require("afs_pb")
local FSRS = require("afs_fsrs")

local Apkg = {}

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, bmp = true, svg = true }

local function num(v) if type(v) == "cdata" then return tonumber(v) end return v end

local function zstd_decompress(str)
    local ok, res = pcall(function() return require("afs_zstdstream").decompress(str) end)
    if ok then return res end
    -- fallback: KOReader's single-shot helper (only works if the frame stores its content size)
    local ok2, res2 = pcall(function()
        local zstd = require("ffi/zstd")
        local ptr, size = zstd.zstd_uncompress(str, #str)
        return ffi.string(ptr, size)
    end)
    if ok2 then return res2 end
    error(tostring(res))
end

local function decode_json(s)
    local ok, v = pcall(JSON.decode, s)
    if ok and type(v) == "table" then return v end
end

local function split_fields(flds)
    local out, pos = {}, 1
    while true do
        local i = flds:find("\31", pos, true)
        if not i then out[#out + 1] = flds:sub(pos); break end
        out[#out + 1] = flds:sub(pos, i - 1); pos = i + 1
    end
    return out
end

-- Generic reader for the temporary Anki collection
local function rows(conn, sql)
    local res = conn:exec(sql)
    local out = {}
    if not res then return out end
    local ncol, nrow = #res, 0
    for c = 1, ncol do if #res[c] > nrow then nrow = #res[c] end end
    for r = 1, nrow do
        local row = {}
        for c = 1, ncol do row[c] = num(res[c][r]) end
        out[r] = row
    end
    return out
end

local function unhex(h)
    if type(h) ~= "string" then return "" end
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

-- FSRS parameters stored in the package's deck options (if any)
local function read_fsrs(conn, has_new)
    local best
    local function consider(w)
        if type(w) == "table" and PB.plausible_params(w) and (not best or #w > #best) then best = w end
    end
    if has_new then
        if #rows(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='deck_config'") > 0 then
            for _, r in ipairs(rows(conn, "SELECT hex(config) FROM deck_config")) do
                consider(PB.fsrs_params(unhex(r[1])))
            end
        end
    else
        local col = rows(conn, "SELECT dconf FROM col")[1]
        for _, conf in pairs(col and decode_json(col[1]) or {}) do
            for _, key in ipairs({ "fsrsParams6", "fsrsParams5", "fsrsWeights" }) do consider(conf[key]) end
        end
    end
    return best
end

local function read_models(conn, has_new)
    local models = {}
    if has_new then
        for _, r in ipairs(rows(conn, "SELECT id, name, hex(config) FROM notetypes")) do
            local cfg = PB.decode(unhex(r[3]))
            models[r[1]] = { name = r[2], kind = tonumber(PB.first(cfg, 1) or 0) or 0, css = PB.first(cfg, 3) or "",
                fields = {}, tmpls = {} }
        end
        for _, r in ipairs(rows(conn, "SELECT ntid, ord, name FROM fields ORDER BY ntid, ord")) do
            local m = models[r[1]]; if m then m.fields[#m.fields + 1] = r[3] end
        end
        for _, r in ipairs(rows(conn, "SELECT ntid, ord, name, hex(config) FROM templates ORDER BY ntid, ord")) do
            local m = models[r[1]]
            if m then
                local cfg = PB.decode(unhex(r[4]))
                m.tmpls[#m.tmpls + 1] = { name = r[3], qfmt = PB.first(cfg, 1) or "", afmt = PB.first(cfg, 2) or "" }
            end
        end
    else
        local col = rows(conn, "SELECT models FROM col")[1]
        local j = col and decode_json(col[1]) or {}
        for mid, m in pairs(j) do
            local mm = { name = m.name, kind = m.type or 0, css = m.css or "", fields = {}, tmpls = {} }
            table.sort(m.flds, function(a, b) return a.ord < b.ord end)
            for _, f in ipairs(m.flds) do mm.fields[#mm.fields + 1] = f.name end
            table.sort(m.tmpls, function(a, b) return a.ord < b.ord end)
            for _, t in ipairs(m.tmpls) do mm.tmpls[#mm.tmpls + 1] = { name = t.name, qfmt = t.qfmt, afmt = t.afmt } end
            models[tonumber(mid)] = mm
        end
    end
    return models
end

local function read_decks(conn, has_new)
    local decks = {}
    if has_new then
        for _, r in ipairs(rows(conn, "SELECT id, name FROM decks")) do decks[r[1]] = (r[2]:gsub("\31", "::")) end
    else
        local col = rows(conn, "SELECT decks FROM col")[1]
        for did, d in pairs(col and decode_json(col[1]) or {}) do decks[tonumber(did)] = d.name end
    end
    return decks
end

-- opts: { media_dir = "...", tmp_dir = "...", rollover = 4 }
-- returns summary table or nil, error message
function Apkg.import(path, store, opts)
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil, "Cannot open the file as a zip archive" end
    local entries = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then entries[entry.path] = true end
    end
    local function extract(name)
        local ok, data = pcall(function() return reader:extractToMemory(name) end)
        if ok then return data end
    end

    -- which collection file?
    local latest = false
    local db_name
    if entries["collection.anki21b"] then db_name, latest = "collection.anki21b", true
    elseif entries["collection.anki21"] then db_name = "collection.anki21"
    elseif entries["collection.anki2"] then db_name = "collection.anki2" end
    if not db_name then reader:close(); return nil, "No Anki collection found inside the package" end

    local blob = extract(db_name)
    if not blob then reader:close(); return nil, "Could not read " .. db_name end
    if latest then
        local ok, res = pcall(zstd_decompress, blob)
        if not ok then reader:close(); return nil, "zstd decompression failed: " .. tostring(res) end
        blob = res
    end
    lfs.mkdir(opts.tmp_dir)
    local tmp_db = opts.tmp_dir .. "/collection.sqlite"
    local f = io.open(tmp_db, "wb")
    if not f then reader:close(); return nil, "Cannot write temporary file" end
    f:write(blob); f:close(); blob = nil

    -- media map: zip entry name -> real file name
    local media = {}
    if entries["media"] then
        local m = extract("media")
        if m and latest then
            local ok, d = pcall(zstd_decompress, m)
            m = ok and d or nil
        end
        if m then
            if latest then
                local idx = 0
                for _, fld in ipairs(PB.decode(m)) do
                    if fld.n == 1 and fld.w == 2 then
                        local name = PB.first(PB.decode(fld.v), 1)
                        local zipname = PB.first(PB.decode(fld.v), 255)
                        media[tostring(zipname and math.floor(zipname) or idx)] = name
                        idx = idx + 1
                    end
                end
            else
                for k, v in pairs(decode_json(m) or {}) do media[k] = v end
            end
        end
    end

    local conn = SQ3.open(tmp_db)
    local has_new = #rows(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='notetypes'") > 0
    local models = read_models(conn, has_new)
    local okp, fsrs_params = pcall(read_fsrs, conn, has_new)
    if not okp then fsrs_params = nil end
    local decks = read_decks(conn, has_new)
    local crt = (rows(conn, "SELECT crt FROM col")[1] or { os.time() })[1]
    local now = os.time()
    local summary = { notes = 0, cards = 0, new_cards = 0, media = 0, fsrs = fsrs_params }

    store:begin()
    for mid, m in pairs(models) do
        store:run("INSERT OR REPLACE INTO models(mid, name, kind, fields, tmpls, css) VALUES(?,?,?,?,?,?)",
            mid, m.name, m.kind, JSON.encode(m.fields), JSON.encode(m.tmpls), m.css)
    end

    -- notes (paged to keep memory low)
    local nid_map, last = {}, 0
    while true do
        local batch = rows(conn, "SELECT id, guid, mid, flds, tags FROM notes WHERE id > " .. last .. " ORDER BY id LIMIT 500")
        if #batch == 0 then break end
        for _, r in ipairs(batch) do
            last = r[1]
            local existing = store:get("SELECT id FROM notes WHERE guid = ?", r[2])
            if existing then
                store:run("UPDATE notes SET mid=?, flds=?, tags=? WHERE id=?", r[3], r[4], r[5], existing)
                nid_map[r[1]] = existing
            else
                store:run("INSERT INTO notes(guid, mid, flds, tags) VALUES(?,?,?,?)", r[2], r[3], r[4], r[5])
                nid_map[r[1]] = store:get("SELECT id FROM notes WHERE guid = ?", r[2])
                summary.notes = summary.notes + 1
            end
        end
    end

    -- cards
    local deck_cache, last_c, card_map = {}, 0, {}
    while true do
        local batch = rows(conn, "SELECT id, nid, did, odid, ord, type, queue, due, ivl, factor, reps, lapses, data FROM cards WHERE id > "
            .. last_c .. " ORDER BY id LIMIT 500")
        if #batch == 0 then break end
        for _, r in ipairs(batch) do
            last_c = r[1]
            local nid = nid_map[r[2]]
            local did_src = (r[4] and r[4] > 0) and r[4] or r[3]
            local dname = decks[did_src] or "Default"
            if not deck_cache[dname] then deck_cache[dname] = store:deckId(dname) end
            if nid then
                local ctype, queue, due, ivl, factor = r[6], r[7], r[8], r[9], r[10]
                local state, step, due_ts, s, d, last_review, pos = 0, 0, 0, nil, nil, nil, 0
                local data = (r[13] and r[13] ~= "") and decode_json(r[13]) or {}
                if ctype == 0 then
                    state, pos = 0, due
                elseif ctype == 2 then
                    state = 2
                    due_ts = crt + due * 86400
                    last_review = data.lrt or (due_ts - math.max(ivl, 1) * 86400)
                    if data.s and data.d then s, d = data.s, data.d
                    else s, d = FSRS.fromSM2(ivl, factor) end
                else -- learning (1) / relearning (3): restart the step, keep what we know
                    state, due_ts = (ctype == 3) and 3 or 1, now
                    if ctype == 3 then s, d = FSRS.fromSM2(math.max(ivl, 1), factor); last_review = now end
                end
                store:run([[INSERT OR IGNORE INTO cards(nid, did, ord, state, step, due, stability, difficulty,
                    last_review, reps, lapses, suspended, pos) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)]],
                    nid, deck_cache[dname], r[5], state, step, due_ts, s or 0, d or 0, last_review or 0, r[11] or 0, r[12] or 0,
                    (queue == -1) and 1 or 0, pos)
                summary.cards = summary.cards + 1
                if state == 0 then summary.new_cards = summary.new_cards + 1 end
                card_map[r[1]] = store:get("SELECT id FROM cards WHERE nid = ? AND ord = ?", nid, r[5])
            end
        end
    end
    -- review history (used by the on-device optimiser and the statistics)
    summary.revlog = 0
    if #rows(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='revlog'") > 0 then
        local last_r = 0
        while true do
            local batch = rows(conn, "SELECT id, cid, ease, type, time, ivl FROM revlog WHERE id > " .. last_r .. " ORDER BY id LIMIT 500")
            if #batch == 0 then break end
            for _, r in ipairs(batch) do
                last_r = r[1]
                local our = card_map[r[2]]
                local ease, rtype = r[3], r[4]
                if our and ease and ease >= 1 and ease <= 4 and (rtype == 0 or rtype == 1 or rtype == 2) then
                    local state = (rtype == 0) and 1 or ((rtype == 1) and 2 or 3)
                    local secs = math.min((r[5] or 0) / 1000, 120)
                    store:run([[INSERT OR IGNORE INTO revlog(cid, ts, rating, state, elapsed, stability, difficulty, ivl, first, secs, imported)
                        VALUES(?,?,?,?,0,0,0,?,0,?,1)]], our, math.floor(r[1] / 1000), ease, state, math.max(r[6] or 0, 0), secs)
                    summary.revlog = summary.revlog + 1
                end
            end
        end
    end
    store:commit()
    conn:close()
    os.remove(tmp_db)

    -- media (images only; an e-ink Kindle has no use for audio)
    lfs.mkdir(opts.media_dir)
    store:begin()
    for zipname, name in pairs(media) do
        local ext = name:match("%.([%w]+)$")
        if ext and IMAGE_EXT[ext:lower()] then
            local data = extract(zipname)
            if data and latest then
                local ok, d = pcall(zstd_decompress, data)
                data = ok and d or nil
            end
            if data then
                local safe = name:gsub("[^%w%._%-]", "_")
                local out = io.open(opts.media_dir .. "/" .. safe, "wb")
                if out then
                    out:write(data); out:close()
                    store:run("INSERT OR REPLACE INTO media(name, file) VALUES(?,?)", name, safe)
                    summary.media = summary.media + 1
                end
            end
        end
    end
    store:commit()
    reader:close()
    return summary
end

Apkg.split_fields = split_fields
return Apkg
