-- Extra screens for Anki FSRS: deck tree, options, statistics, browser, note editing, optimiser UI.
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Screen = Device.screen

local FSRS = require("afs_fsrs")
local Render = require("afs_render")
local Apkg = require("afs_apkg")
local Opt = require("afs_optimizer")
local C = require("afs_common")
local U = require("afs_util")
local D = C.DEFAULTS

return function(AnkiFSRS, _env)

local function day_times(self)
    local now = os.time()
    local ro = self.settings:readSetting("rollover", D.rollover)
    return now, FSRS.dayStart(now, ro), FSRS.dayOffset(now, 1, ro), ro
end

---------------------------------------------------------------------------------------------
-- Small dialogs (shared by the options screen and the KOReader settings menu)
---------------------------------------------------------------------------------------------
function AnkiFSRS:applyParamText(text)
    if text:match("^%s*$") then
        self.settings:delSetting("weights"); self.settings:flush()
        return self:toast(_("Using default parameters."))
    end
    local list = {}
    for tok in text:gmatch("[^%s,%[%]]+") do list[#list + 1] = tonumber(tok) end
    local ok, err = FSRS.normalizeParams(list)
    if ok then self:set("weights", ok); self:toast(_("Parameters saved."))
    else self:toast(_("Invalid parameters: ") .. tostring(err)) end
end

function AnkiFSRS:loadParamsFile(on_done)
    lfs.mkdir(C.DATA_DIR)
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true, path = C.DATA_DIR,
        file_filter = function(name) local n = name:lower(); return n:match("%.txt$") ~= nil or n:match("%.json$") ~= nil end,
        onConfirm = function(path)
            local f = io.open(path, "r")
            local text = f and f:read("*a") or ""
            if f then f:close() end
            self:applyParamText(text)
            if on_done then on_done() end
        end,
    })
end

function AnkiFSRS:retentionDialog(on_done)
    self:textInput(_("Desired retention (0.70 – 0.99)"), tostring(self.settings:readSetting("retention", D.retention)), "0.90",
        function(t)
            local v = tonumber(t)
            if v and v >= 0.7 and v <= 0.99 then self:set("retention", v); if on_done then on_done() end
            else self:toast(_("Enter a number between 0.70 and 0.99")) end
        end)
end

function AnkiFSRS:examDialog(on_done)
    self:textInput(_("Exam date (YYYY-MM-DD, empty = none)"), self.settings:readSetting("exam_date", ""), "2027-03-15",
        function(t)
            t = t:gsub("%s", "")
            if t == "" or t:match("^%d%d%d%d%-%d%d?%-%d%d?$") then
                self:set("exam_date", t); if on_done then on_done() end
                self:toast(t == "" and _("Exam date cleared.") or
                    string.format(_("Intervals will not go beyond %d days."), self:effectiveMaxInterval()))
            else self:toast(_("Use the format YYYY-MM-DD")) end
        end)
end

function AnkiFSRS:presetDialog(on_done)
    local dlg
    local rows = {}
    for _i, p in ipairs(C.PRESETS) do
        rows[#rows + 1] = { { text = p.name, callback = function()
            UIManager:close(dlg)
            self:set("retention", p.retention); self:set("learning_steps", p.learning_steps)
            self:set("relearning_steps", p.relearning_steps)
            if on_done then on_done() end
            self:toast(string.format(_("Preset applied: %s"), p.name), 2)
        end } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = _("Presets (retention + learning steps)"), buttons = rows }
    UIManager:show(dlg)
end

function AnkiFSRS:frontlight()
    local ok, W = pcall(require, "ui/widget/frontlightwidget")
    if ok and W then UIManager:show(W:new{}) else UIManager:broadcastEvent(Event:new("ShowFlDialog")) end
end

function AnkiFSRS:toggleLight()
    if Device.powerd and Device.powerd.toggleFrontlight then Device.powerd:toggleFrontlight() end
end

-- KOReader's own night mode (screen-wide inversion), toggled exactly like its built-in menu does
function AnkiFSRS:nightModeOn()
    if G_reader_settings.isTrue then return G_reader_settings:isTrue("night_mode") end
    return G_reader_settings:readSetting("night_mode") == true
end

function AnkiFSRS:toggleNightMode(on_done)
    local was = self:nightModeOn()
    local ok = pcall(function() Screen:toggleNightMode() end)
    if not ok then return self:toast(_("Night mode is not available on this KOReader version.")) end
    G_reader_settings:saveSetting("night_mode", not was)
    UIManager:setDirty("all", "full")
    if on_done then on_done() end
end

---------------------------------------------------------------------------------------------
-- Options (reachable from the deck list and from inside a review session)
---------------------------------------------------------------------------------------------
local function cycle(map_order, current)
    for i, k in ipairs(map_order) do
        if k == current then return map_order[i % #map_order + 1] end
    end
    return map_order[1]
end

function AnkiFSRS:showOptions(review)
    local s = self.settings
    local dlg
    local function done() if review then review:build() end end
    local function act(fn) return function() UIManager:close(dlg); fn() end end
    local function toggle(label, key)
        return { text = label .. ": " .. (s:readSetting(key, D[key]) and _("ON") or _("OFF")),
            callback = act(function() self:set(key, not s:readSetting(key, D[key])); done() end) }
    end
    local rows = {
        { toggle(_("Pass/Fail"), "pass_fail"), toggle(_("Swap keys"), "swap_keys") },
        { toggle(_("Repeat after Fail"), "repeat_on_fail"),
          { text = _("Night mode: ") .. (self:nightModeOn() and _("ON") or _("OFF")),
            callback = act(function() self:toggleNightMode(done) end) } },
        { { text = _("Card font size"), callback = act(self:spin(_("Card font size"), "font_size", 10, 60, 1, done)) },
          toggle(_("Center text"), "center_text") },
    }
    if review and review.card then
        local cur = review.card
        rows[#rows + 1] = { { text = _("Suspend card"), callback = act(function() review:suspend() end) },
            { text = _("Skip until tomorrow"), callback = act(function() review:buryCard() end) } }
        rows[#rows + 1] = { { text = _("Edit note"), callback = act(function()
                self:editNote(cur.nid, function() review:refreshCurrent() end) end) },
            { text = _("Card info"), callback = act(function()
                self:showCardInfo(cur.id, function() review:refreshCurrent() end) end) } }
    end
    if Device:hasFrontlight() then
        rows[#rows + 1] = { { text = _("Frontlight…"), callback = act(function() self:frontlight() end) },
            { text = _("Light on/off"), callback = act(function() self:toggleLight() end) } }
    end
    rows[#rows + 1] = { { text = _("Statistics"), callback = act(function() self:showStats() end) },
        { text = _("Browse cards"), callback = act(function() self:showBrowse(review and review.deck_name or nil) end) } }
    rows[#rows + 1] = { { text = _("More settings…"), callback = act(function() self:showMoreSettings(review) end) } }
    rows[#rows + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = _("Anki FSRS options"), buttons = rows }
    UIManager:show(dlg)
end

function AnkiFSRS:showMoreSettings(review)
    local s = self.settings
    local dlg
    local function done() if review then review:build() end end
    local function act(fn) return function() UIManager:close(dlg); fn() end end
    local ro_order, no_order = { "due", "random", "overdue" }, { "pos", "random" }
    local rows = {
        { { text = _("New cards / day"), callback = act(self:spin(_("New cards per day"), "new_per_day", 0, 9999, 1, done)) },
          { text = _("Reviews / day"), callback = act(self:spin(_("Maximum reviews per day"), "reviews_per_day", 0, 9999, 1, done)) } },
        { { text = _("Review order: ") .. C.REVIEW_ORDERS[s:readSetting("review_order", D.review_order)],
            callback = act(function() self:set("review_order", cycle(ro_order, s:readSetting("review_order", D.review_order))); self:showMoreSettings(review) end) } },
        { { text = _("New card order: ") .. C.NEW_ORDERS[s:readSetting("new_order", D.new_order)],
            callback = act(function() self:set("new_order", cycle(no_order, s:readSetting("new_order", D.new_order))); self:showMoreSettings(review) end) } },
        { { text = _("Bury siblings: ") .. (s:readSetting("bury_siblings", D.bury_siblings) and _("ON") or _("OFF")),
            callback = act(function() self:set("bury_siblings", not s:readSetting("bury_siblings", D.bury_siblings)); self:showMoreSettings(review) end) } },
    }
    if review and review.deck_name then
        rows[#rows + 1] = { { text = _("Deck settings…"), callback = act(function() self:deckSettingsDialog(review.deck_name, done) end) } }
    end
    rows[#rows + 1] = { { text = _("Desired retention"), callback = act(function() self:retentionDialog(done) end) },
        { text = _("Presets"), callback = act(function() self:presetDialog(done) end) } }
    rows[#rows + 1] = { { text = _("Exam date"), callback = act(function() self:examDialog(done) end) },
        { text = _("Params from file"), callback = act(function() self:loadParamsFile(done) end) } }
    rows[#rows + 1] = { { text = _("Leech threshold"), callback = act(self:spin(_("Leech threshold (lapses, 0 = off)"), "leech_threshold", 0, 50, 1, done)) },
        { text = _("Refresh every N"), callback = act(self:spin(_("Full refresh every N cards (0 = never)"), "refresh_every", 0, 100, 1, done)) } }
    rows[#rows + 1] = { { text = _("Optimise FSRS parameters"), callback = act(function() self:optimize() end) } }
    rows[#rows + 1] = { { text = _("Back"), callback = act(function() self:showOptions(review) end) },
        { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = _("More settings"), buttons = rows }
    UIManager:show(dlg)
end

---------------------------------------------------------------------------------------------
-- Deck tree with per-deck limits
---------------------------------------------------------------------------------------------
-- Per-deck settings: daily limits and desired retention. Retention is inherited from parent decks.
function AnkiFSRS:deckSettingsDialog(name, on_done)
    local store = self:getStore()
    local dlg
    local function reopen() if on_done then on_done() end; self:deckSettingsDialog(name, on_done) end
    local function act(fn) return function() UIManager:close(dlg); fn() end end
    local o = store:deckOpts(name)
    local gnew, grev = self:limitsFor(nil)
    local parts = U.split_name(name)
    local label = U.truncate(parts[#parts], 30)

    local function limit_row(text_fmt, key, current, global, title)
        return { { text = string.format(text_fmt, current and tostring(current) or string.format(_("global (%d)"), global)),
            callback = act(function()
                UIManager:show(SpinWidget:new{
                    title_text = string.format("%s – %s", title, label), value = current or global,
                    value_min = 0, value_max = 9999, value_step = 1, value_hold_step = 10, ok_text = _("Set"),
                    callback = function(sp) store:setDeckOpt(name, key, math.floor(sp.value)); reopen() end,
                })
            end) } }
    end

    local own = o.retention
    local inherited, from = self:retentionForName(name)
    local ret_text
    if own then ret_text = string.format("%d%%", math.floor(own * 100 + 0.5))
    elseif inherited then ret_text = string.format(_("%d%% (from %s)"), math.floor(inherited * 100 + 0.5), U.truncate(from:match("([^:]+)$") or from, 20))
    else ret_text = string.format(_("global (%d%%)"), math.floor(self.settings:readSetting("retention", D.retention) * 100 + 0.5)) end

    local rows = {
        limit_row(_("New cards / day: %s"), "new", o.new, gnew, _("New cards per day")),
        limit_row(_("Reviews / day: %s"), "rev", o.rev, grev, _("Max reviews per day")),
        { { text = string.format(_("Desired retention: %s"), ret_text), callback = act(function()
            self:textInput(string.format(_("Desired retention for %s (0.70 – 0.99, empty = inherit)"), label),
                own and tostring(own) or "", "0.95", function(t)
                    t = t:gsub("%s", "")
                    if t == "" then store:setDeckOpt(name, "retention", nil); return reopen() end
                    local v = tonumber(t)
                    if v and v >= 0.7 and v <= 0.99 then store:setDeckOpt(name, "retention", v); reopen()
                    else self:toast(_("Enter a number between 0.70 and 0.99")) end
                end)
        end) } },
    }
    if o.new or o.rev or o.retention then
        rows[#rows + 1] = { { text = _("Reset this deck's settings"), callback = act(function() store:clearDeckOpts(name); reopen() end) } }
    end
    rows[#rows + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = string.format(_("Deck settings: %s"), U.truncate(name, 50)), buttons = rows }
    UIManager:show(dlg)
end
AnkiFSRS.deckLimitsDialog = AnkiFSRS.deckSettingsDialog

function AnkiFSRS:deckMenu(name, rebuild)
    local dlg
    local function act(fn) return function() UIManager:close(dlg); fn() end end
    local rows = {
        { { text = _("Read through this deck"), callback = act(function() self:readThroughDeck(name) end) } },
        { { text = _("Browse cards in this deck"), callback = act(function() self:showBrowse(name) end) } },
        { { text = _("Deck settings (limits, retention)…"), callback = act(function() self:deckSettingsDialog(name, rebuild) end) } },
        { { text = _("Close"), callback = function() UIManager:close(dlg) end } },
    }
    dlg = ButtonDialog:new{ title = U.truncate(name, 60), buttons = rows }
    UIManager:show(dlg)
end

function AnkiFSRS:showDecks()
    local store = self:getStore()
    local menu
    local function expanded_set() return self.settings:readSetting("expanded_decks", {}) end

    local function start(name)
        UIManager:close(menu)
        self:study(name, function() self:showDecks() end)
    end

    local build_items
    local function rebuild()
        local ok, items = pcall(build_items)
        if ok then menu:switchItemTable(nil, items)
        else self:toast("Anki FSRS error (deck list):\n" .. tostring(items), 10) end
    end

    build_items = function()
        local now, day_start, day_end = day_times(self)
        local ids_all = store:deckIds(nil)
        local function counts_for(name)
            local nl, rl = self:limitsFor(name)
            return store:counts(name and store:deckIds(name) or ids_all, now, day_end, day_start, nl, rl, C.LEARN_AHEAD)
        end
        local function mandatory(name)
            local n, l, r = counts_for(name)
            return string.format("%d | %d | %d", n, l, r)
        end
        local items = {
            { text = _("Options…"), callback = function() self:showOptions(nil) end },
            { text = _("Study all decks"), mandatory = mandatory(nil), callback = function() start(nil) end },
        }
        local pet_text, pet_count = self:petRow()
        if pet_text then table.insert(items, 2, { text = pet_text, mandatory = pet_count, callback = function() self:showPet() end }) end

        -- build the tree from the "A::B::C" names
        local nodes, roots = {}, {}
        for _i, full in ipairs(store:deckNames()) do
            local path, prev
            for depth, part in ipairs(U.split_name(full)) do
                path = path and (path .. "::" .. part) or part
                if not nodes[path] then
                    nodes[path] = { name = path, label = part, depth = depth - 1, children = {}, parent = prev }
                    if prev then table.insert(nodes[prev].children, nodes[path]) else table.insert(roots, nodes[path]) end
                end
                prev = path
            end
        end
        local function sort_nodes(list) table.sort(list, function(a, b) return a.label < b.label end) end
        sort_nodes(roots)

        local exp = expanded_set()
        local function visit(node)
            local total = store:scalar("SELECT COUNT(*) FROM cards WHERE did IN " .. require("afs_store").in_list(store:deckIds(node.name))) or 0
            if total == 0 then return end
            local indent = string.rep("    ", node.depth)
            local own_ret = store:deckOpts(node.name).retention
            local tag = own_ret and string.format("  [%d%%]", math.floor(own_ret * 100 + 0.5)) or ""
            if #node.children > 0 then
                local open = exp[node.name] == true
                items[#items + 1] = {
                    text = indent .. (open and "[-] " or "[+] ") .. node.label .. tag,
                    mandatory = mandatory(node.name),
                    callback = function()
                        local e = expanded_set(); e[node.name] = (not open) or nil
                        self:set("expanded_decks", e)
                        rebuild()
                    end,
                    hold_callback = function() self:deckMenu(node.name, function() rebuild() end) end,
                }
                if open then
                    items[#items + 1] = {
                        text = indent .. "      " .. _("▶ Study all of this deck"),
                        callback = function() start(node.name) end,
                        hold_callback = function() self:deckMenu(node.name, function() rebuild() end) end,
                    }
                    sort_nodes(node.children)
                    for _j, child in ipairs(node.children) do visit(child) end
                end
            else
                items[#items + 1] = {
                    text = indent .. "     " .. node.label .. tag,
                    mandatory = mandatory(node.name),
                    callback = function() start(node.name) end,
                    hold_callback = function() self:deckMenu(node.name, function() rebuild() end) end,
                }
            end
        end
        for _j, root in ipairs(roots) do visit(root) end
        return items
    end

    if #store:deckNames() == 0 then
        return self:toast(_("No decks yet. Use “Import .apkg” first."))
    end
    menu = Menu:new{
        title = _("Decks  (new | learning | due)   hold = deck options"),
        item_table = build_items(), is_borderless = true, is_popout = false, covers_fullscreen = true,
        width = Screen:getWidth(), height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

---------------------------------------------------------------------------------------------
-- Statistics and forecast
---------------------------------------------------------------------------------------------
function AnkiFSRS:showStats()
    local store = self:getStore()
    local now, day_start, day_end, ro = day_times(self)
    local phase = day_start % 86400
    local totals = store:cardTotals()
    local today = store:reviewCount(day_start)
    local avg = store:avgSecs(day_start - 30 * 86400)
    local streak, days_studied = store:streak(phase, math.floor((day_start - phase) / 86400))
    local nl, rl = self:limitsFor(nil)
    local n, l, r = store:counts(store:deckIds(nil), now, day_end, day_start, nl, rl, C.LEARN_AHEAD)
    local fc = store:forecast(day_start, 30)

    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(string.format(_("TODAY   reviewed %d   due now: %d new, %d learning, %d review"), today, n, l, r))
    if avg then
        add(string.format(_("Average %.0f s per card; clearing today ≈ %s"), avg, U.duration(avg * (n + l + r))))
    end
    add(string.format(_("STREAK  %d day(s)   (%d days studied in total)"), streak, days_studied))
    add("")
    add(_("RETENTION (review cards, not 'Again')"))
    local function ret(since) local v, c = store:retention(since); return v and string.format("%s (%d)", U.pct(v), c) or "–" end
    add(string.format(_("  today %s    7 days %s"), ret(day_start), ret(day_start - 6 * 86400)))
    add(string.format(_("  30 days %s    all-time %s"), ret(day_start - 29 * 86400), ret(0)))
    add(string.format(_("  target: %d%%"), math.floor(self.settings:readSetting("retention", D.retention) * 100 + 0.5)))
    add("")
    add(_("FORECAST (reviews due)"))
    local max = 0
    for d = 0, 6 do if fc[d] > max then max = fc[d] end end
    for d = 0, 6 do
        local label = d == 0 and _("Today") or os.date("%a %d", day_start + d * 86400 + 12 * 3600)
        add(string.format("  %-8s %4d %s", label, fc[d], U.bar(fc[d], max, 20)))
    end
    local s7, s30 = 0, 0
    for d = 0, 29 do s30 = s30 + fc[d]; if d < 7 then s7 = s7 + fc[d] end end
    add(string.format(_("  next 7 days: %d (%.0f/day)"), s7, s7 / 7))
    add(string.format(_("  next 30 days: %d (%.0f/day)"), s30, s30 / 30))
    if s7 / 7 > rl then add(_("  ! heavier than your daily review limit")) end
    local ex = self.settings:readSetting("exam_date", "")
    if ex ~= "" then
        add("")
        add(string.format(_("EXAM %s – intervals capped at %d days"), ex, self:effectiveMaxInterval()))
    end
    add("")
    add(string.format(_("CARDS  total %d  new %d  learning %d  review %d"), totals.total, totals.new, totals.learning, totals.review))
    add(string.format(_("       mature %d  suspended %d  leeches %d"), totals.mature, totals.suspended, totals.leeches))

    UIManager:show(TextViewer:new{
        title = _("Statistics & forecast"), text = table.concat(lines, "\n"),
        width = Screen:getWidth() - Screen:scaleBySize(20), height = Screen:getHeight() - Screen:scaleBySize(40),
        monospace_font = true,
    })
end

---------------------------------------------------------------------------------------------
-- Card browser with smart filters
---------------------------------------------------------------------------------------------
local function state_metric(c)
    if (c.suspended or 0) == 1 then return c.leech == 1 and _("leech") or _("susp") end
    if c.state == 0 then return _("new") end
    if c.state == 1 or c.state == 3 then return _("learning") end
    return string.format("%.0fd", c.stability or 0)
end

local function front_text(flds)
    local first = Apkg.split_fields(flds)[1] or ""
    first = first:gsub("{{c%d+::([^{}]-)}}", function(x) return (x:gsub("::.*$", "")) end)
    return U.one_line(first, 70)
end

function AnkiFSRS:showCardInfo(card_id, on_done)
    local store = self:getStore()
    local info, card = store:cardInfo(card_id), store:cardById(card_id)
    if not info or not card then return self:toast(_("Card not found.")) end
    local now, _ds, _de, ro = day_times(self)
    local q, a = self:renderCard(card)
    local state_names = { [0] = _("new"), [1] = _("learning"), [2] = _("review"), [3] = _("relearning") }
    local lines = { U.html_to_text(q or ""), "", "———", "", U.html_to_text(a or ""), "", "———" }
    local r_now
    if info.state == 2 and info.stability > 0 then
        local t = info.last_review > 0 and FSRS.daysBetween(info.last_review, now, ro) or 0
        r_now = self:getFsrs():retrievability(t, info.stability)
    end
    lines[#lines + 1] = string.format(_("State: %s    Reviews: %d    Lapses: %d"), state_names[info.state] or "?", info.reps, info.lapses)
    if info.state ~= 0 then
        lines[#lines + 1] = string.format(_("Stability: %.1f d    Difficulty: %.1f/10    Recall now: %s"),
            info.stability, info.difficulty, r_now and string.format("%.0f%%", r_now * 100) or "–")
        lines[#lines + 1] = string.format(_("Last review: %s    Due: %s"), U.date(info.last_review), U.date(info.due))
    end
    if info.avg_secs then lines[#lines + 1] = string.format(_("Average answer time: %.0f s"), info.avg_secs) end
    if info.suspended == 1 then lines[#lines + 1] = info.leech == 1 and _("SUSPENDED (leech)") or _("SUSPENDED") end
    if info.buried > now then lines[#lines + 1] = _("Skipped until tomorrow") end

    local viewer
    local function act(fn) return function() UIManager:close(viewer); self:safeCall(fn, "card action"); if on_done then on_done() end end end
    viewer = TextViewer:new{
        title = _("Card"), text = table.concat(lines, "\n"),
        width = Screen:getWidth() - Screen:scaleBySize(20), height = Screen:getHeight() - Screen:scaleBySize(40),
        buttons_table = {
            { { text = info.suspended == 1 and _("Unsuspend") or _("Suspend"),
                callback = act(function() store:setSuspended(card_id, info.suspended ~= 1) end) },
              { text = _("Unskip"), enabled = info.buried > now, callback = act(function() store:unbury({ card_id }) end) } },
            { { text = _("Edit note"), callback = function() UIManager:close(viewer); self:editNote(card.nid, on_done) end },
              { text = _("Forget (make new)"), callback = act(function() store:forget(card_id); self:toast(_("Card reset to new."), 2) end) } },
            { { text = _("Close"), callback = function() UIManager:close(viewer) end } },
        },
    }
    UIManager:show(viewer)
end

function AnkiFSRS:showBrowseResults(title, list, metric, deck_name, filter_again)
    if #list == 0 then return self:toast(_("No cards match.")) end
    local items = {}
    local all_ids, study_ids = {}, {}
    for _i, info in ipairs(list) do all_ids[#all_ids + 1] = info.id end
    items[#items + 1] = { text = string.format(_("Read through these %d cards"), #all_ids),
        callback = function() self:previewCards(all_ids, 1) end }
    for _i, info in ipairs(list) do if info.suspended ~= 1 then study_ids[#study_ids + 1] = info.id end end
    if #study_ids > 0 then
        items[#items + 1] = { text = string.format(_("▶ Study these %d cards"), #study_ids),
            callback = function() self:study(nil, nil, study_ids) end }
        if #study_ids > 20 then
            items[#items + 1] = { text = _("▶ Study just the first 20"), callback = function()
                local first = {}
                for i = 1, 20 do first[i] = study_ids[i] end
                self:study(nil, nil, first)
            end }
        end
    end
    for idx, info in ipairs(list) do
        items[#items + 1] = {
            text = front_text(info.flds), mandatory = metric(info),
            hold_callback = function() self:previewCards(all_ids, idx) end,
            callback = function() self:showCardInfo(info.id, function() if filter_again then filter_again() end end) end,
        }
    end
    UIManager:show(Menu:new{
        title = string.format("%s (%d)", title, #list), item_table = items, is_borderless = true, is_popout = false,
        covers_fullscreen = true, width = Screen:getWidth(), height = Screen:getHeight(),
    })
end

function AnkiFSRS:showBrowse(deck_name)
    local store = self:getStore()
    local ids = store:deckIds(deck_name)
    local now, _ds, _de, ro = day_times(self)
    local fsrs = self:getFsrs()
    local week_ago = now - 7 * 86400

    local function recall(info)
        local t = info.last_review > 0 and FSRS.daysBetween(info.last_review, now, ro) or 0
        return fsrs:retrievability(t, info.stability)
    end
    local function run(title, fetch, metric)
        local function go() self:showBrowseResults(title, fetch(), metric, deck_name, nil) end
        go()
    end

    local now_ts, day_start_ts, day_end_ts = day_times(self)
    local filters = {
        { text = deck_name and _("All cards in this deck") or _("All cards"), run = function()
            run(deck_name and _("All cards in this deck") or _("All cards"),
                function() return store:browse(ids, nil, "c.nid, c.ord", 3000) end, state_metric)
        end },
        { text = _("Read through this deck (question + answer)"), run = function() self:readThroughDeck(deck_name) end },
        { text = _("Preview today's new cards"), run = function() self:previewNewCards(deck_name) end },
        { text = _("Due today"), run = function()
            run(_("Due today"), function()
                return store:browse(ids, "c.suspended = 0 AND ((c.state = 2 AND c.due < " .. day_end_ts .. ") OR c.state IN (1,3))", "c.due", 3000)
            end, state_metric)
        end },
        { text = _("Danger zone: lowest recall right now"), run = function()
            run(_("Danger zone"), function()
                local list = store:browse(ids, "c.state = 2 AND c.suspended = 0 AND c.stability > 0", "c.due", 4000)
                for _i, c in ipairs(list) do c.r = recall(c) end
                table.sort(list, function(a, b) return a.r < b.r end)
                local out = {}
                for i = 1, math.min(#list, 200) do out[i] = list[i] end
                return out
            end, function(c) return string.format("R %.0f%%", c.r * 100) end)
        end },
        { text = _("Leeches (failed too often)"), run = function()
            run(_("Leeches"), function() return store:browse(ids, "c.leech = 1", "c.lapses DESC") end,
                function(c) return string.format("%d lapses", c.lapses) end)
        end },
        { text = _("Most lapses (3 or more)"), run = function()
            run(_("Most lapses"), function() return store:browse(ids, "c.lapses >= 3 AND c.suspended = 0", "c.lapses DESC") end,
                function(c) return string.format("%d lapses", c.lapses) end)
        end },
        { text = _("High difficulty (8 or more)"), run = function()
            run(_("High difficulty"), function() return store:browse(ids, "c.state = 2 AND c.difficulty >= 8 AND c.suspended = 0", "c.difficulty DESC") end,
                function(c) return string.format("D %.1f", c.difficulty) end)
        end },
        { text = _("Fragile: stability under 7 days after 3+ reviews"), run = function()
            run(_("Fragile"), function() return store:browse(ids, "c.state = 2 AND c.reps >= 3 AND c.stability < 7 AND c.suspended = 0", "c.stability") end,
                function(c) return string.format("S %.1f d", c.stability) end)
        end },
        { text = _("Failed in the last 7 days"), run = function()
            run(_("Failed recently"), function()
                return store:browse(ids, "c.id IN (SELECT cid FROM revlog WHERE rating = 1 AND ts >= " .. math.floor(week_ago) .. ")", "c.last_review DESC")
            end, function(c) return U.date(c.last_review) end)
        end },
        { text = _("Slowest to answer"), run = function()
            run(_("Slowest"), function() return store:browseSlowest(ids) end,
                function(c) return string.format("%.0f s", c.avg_secs or 0) end)
        end },
        { text = _("Suspended"), run = function()
            run(_("Suspended"), function() return store:browse(ids, "c.suspended = 1", "c.lapses DESC") end,
                function(c) return c.leech == 1 and _("leech") or "" end)
        end },
        { text = _("Skipped until tomorrow"), run = function()
            run(_("Skipped"), function() return store:browse(ids, "c.buried_until > " .. now, "c.id") end, function() return "" end)
        end },
        { text = _("New (not studied yet)"), run = function()
            run(_("New cards"), function() return store:browse(ids, "c.state = 0 AND c.suspended = 0", "c.pos, c.id") end, function() return "" end)
        end },
        { text = _("Search text…"), run = function()
            self:textInput(_("Search in card text"), "", _("word or phrase"), function(t)
                if t:match("^%s*$") then return end
                run(string.format(_("Search: %s"), U.truncate(t, 20)), function() return store:browseSearch(ids, t) end,
                    function(c) return c.state == 0 and _("new") or string.format("S %.0fd", c.stability) end)
            end)
        end },
    }
    local items = {}
    for _i, f in ipairs(filters) do
        items[#items + 1] = { text = f.text, callback = function() self:safeCall(f.run, "browse: " .. f.text) end }
    end
    UIManager:show(Menu:new{
        title = deck_name and string.format(_("Browse: %s"), U.truncate(deck_name, 40)) or _("Browse all cards"),
        item_table = items, is_borderless = true, is_popout = false, covers_fullscreen = true,
        width = Screen:getWidth(), height = Screen:getHeight(),
    })
end

---------------------------------------------------------------------------------------------
-- Edit a note on the device (fix typos)
---------------------------------------------------------------------------------------------
function AnkiFSRS:editNote(nid, on_done)
    local store = self:getStore()
    local flds, mid = store:noteFields(nid)
    if not flds then return self:toast(_("Note not found.")) end
    local row = store:getRow("SELECT fields FROM models WHERE mid = ?", mid)
    local names = row and JSON.decode(row[1]) or {}
    local vals = Apkg.split_fields(flds)
    local dlg
    local rows = {}
    for i, v in ipairs(vals) do
        rows[#rows + 1] = { { text = string.format("%s: %s", names[i] or ("#" .. i), U.one_line(v, 28)), callback = function()
            UIManager:close(dlg)
            self:textInput(string.format(_("Edit “%s” (HTML shown as-is)"), names[i] or i), v, "", function(t)
                vals[i] = t
                store:updateNoteFields(nid, table.concat(vals, "\31"))
                self:toast(_("Saved on this device. Importing the same deck again will overwrite the edit."), 3)
                if on_done then on_done() end
            end, true)
        end } }
    end
    rows[#rows + 1] = { { text = _("Close"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = _("Edit note: choose a field"), buttons = rows }
    UIManager:show(dlg)
end

---------------------------------------------------------------------------------------------
-- On-device FSRS optimiser
---------------------------------------------------------------------------------------------
function AnkiFSRS:optimize()
    local store = self:getStore()
    local _now, day_start = day_times(self)
    local seqs = Opt.buildSequences(store:revlogRows(), day_start % 86400)
    local usable = Opt.countLong(seqs)
    if usable < 300 then
        return self:toast(string.format(
            _("Not enough review history yet: %d usable reviews.\nNeed at least 300 (1000+ recommended). Re-import a deck exported from Anki with scheduling information to bring in your past reviews."), usable), 6)
    end
    local old = FSRS.normalizeParams(self.settings:readSetting("weights") or FSRS.DEFAULT_W) or FSRS.normalizeParams(FSRS.DEFAULT_W)
    local opt = Opt.new(seqs, old)
    local cancelled, replacing, info = false, false, nil
    local function show(text)
        if info then replacing = true; UIManager:close(info); replacing = false end
        info = InfoMessage:new{ text = text, dismiss_callback = function() if not replacing then cancelled = true end end }
        UIManager:show(info)
        UIManager:forceRePaint()
    end
    show(string.format(_("Optimising FSRS parameters on %d reviews…\nThis can take a few minutes. Tap to cancel."), usable))
    local last_ui = os.clock()
    local function tick()
        if cancelled then return end
        local finished = opt:run(1.5)
        if finished then
            if info then replacing = true; UIManager:close(info); replacing = false end
            return self:optimizeFinished(opt, old)
        end
        if os.clock() - last_ui > 10 then
            last_ui = os.clock()
            show(string.format(_("Optimising… pass %d\nTap to cancel."), opt.pass))
        end
        UIManager:scheduleIn(0.05, tick)
    end
    UIManager:scheduleIn(0.3, tick)
end

function AnkiFSRS:optimizeFinished(opt, old)
    local r = opt:result()
    local text = string.format(_("Prediction error on held-out reviews: %.4f → %.4f\nOn training reviews: %.4f → %.4f\n(%d train / %d test reviews; lower is better)"),
        r.test_before, r.test_after, r.train_before, r.train_after, r.n_train, r.n_test)
    if not r.better then
        return self:toast(text .. "\n\n" .. _("No reliable improvement over your current parameters, so nothing was changed."), 8)
    end
    local w = {}
    for i, v in ipairs(r.w) do w[i] = math.floor(v * 10000 + 0.5) / 10000 end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Apply the new parameters?"),
        ok_text = _("Apply"), cancel_text = _("Keep current"),
        ok_callback = function()
            self:set("weights_backup", old)
            self:set("weights", w)
            self:toast(_("New parameters applied. You can undo this under Settings → restore previous."), 3)
        end,
    })
end

function AnkiFSRS:restoreParams()
    local b = self.settings:readSetting("weights_backup")
    if type(b) ~= "table" then return self:toast(_("No previous parameters saved.")) end
    local cur = self.settings:readSetting("weights")
    self:set("weights", b)
    self:set("weights_backup", cur)
    self:toast(_("Previous parameters restored."), 2)
end

end
