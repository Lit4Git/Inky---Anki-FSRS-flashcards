local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local PathChooser = require("ui/widget/pathchooser")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local FSRS = require("afs_fsrs")
local Render = require("afs_render")
local Apkg = require("afs_apkg")
local Store = require("afs_store")
local C = require("afs_common")
local U = require("afs_util")

local DEFAULTS, DATA_DIR, MEDIA_DIR, LEARN_AHEAD = C.DEFAULTS, C.DATA_DIR, C.MEDIA_DIR, C.LEARN_AHEAD

---------------------------------------------------------------------------------------------
-- Review screen
---------------------------------------------------------------------------------------------
local ReviewScreen = InputContainer:extend{
    covers_fullscreen = true,
    plugin = nil, deck_name = nil, on_close = nil,
    card_ids = nil,   -- optional fixed list of card ids (a session on a Browse list)
}

function ReviewScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.store, self.cfg = self.plugin:getStore(), self.plugin.settings
    self.undo_stack, self.answered, self.qpos = {}, 0, 0
    self.ids = self.store:deckIds(self.deck_name)
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            Advance = { { Device.input.group.PgFwd } },
            Rewind = { { Device.input.group.PgBack } },
        }
    end
    self:loadNext()
end

function ReviewScreen:times()
    local now = os.time()
    local ro = self.cfg:readSetting("rollover", DEFAULTS.rollover)
    return now, FSRS.dayStart(now, ro), FSRS.dayOffset(now, 1, ro), ro
end

function ReviewScreen:limits() return self.plugin:limitsFor(self.deck_name) end

function ReviewScreen:loadNext()
    self.practice = false
    if self.card_ids then return self:nextFromList() end
    local now, day_start, day_end = self:times()
    local new_limit, rev_limit = self:limits()
    local card = self.store:nextCard(self.ids, now, day_end, day_start, new_limit, rev_limit, LEARN_AHEAD, {
        review_order = self.cfg:readSetting("review_order", DEFAULTS.review_order),
        new_order = self.cfg:readSetting("new_order", DEFAULTS.new_order),
    })
    self:present(card)
end

-- Session on a fixed list of cards: each card once, in list order, skipping suspended ones
function ReviewScreen:nextFromList()
    while true do
        self.qpos = self.qpos + 1
        local id = self.card_ids[self.qpos]
        if not id then return self:present(nil) end
        local card = self.store:cardById(id)
        if card and (card.suspended or 0) == 0 then return self:present(card) end
    end
end

-- Show a specific card (or the "all done" screen when card is nil)
function ReviewScreen:present(card)
    local _now, _ds, _de, ro = self:times()
    self.practice = false
    self.card, self.showing_answer = card, false
    if card then
        -- each card is scheduled with the retention of its own deck (or an ancestor deck)
        self.fsrs = self.plugin:getFsrs(self.plugin:retentionForDeck(card.did))
        local q, a, model = self.plugin:renderCard(card)
        if not q then
            self.store:setSuspended(card.id, true)   -- orphaned card; skip it
            return self:loadNext()
        end
        self.q_html, self.a_html, self.model = q, a, model
        self.preview = self.fsrs:preview(card, os.time(), ro)
        self.shown_at = C.now_precise()
    end
    self:build()
end

function ReviewScreen:css()
    local css = [[
        @page { margin: 0; }
        body { margin: 0; padding: 0; }
        .cloze { font-weight: bold; }
        .hint { color: #444444; font-size: 0.8em; }
        hr { margin: 0.7em 0; }
        img { max-width: 100%; }
        a { color: inherit; text-decoration: none; }
    ]]
    if self.cfg:readSetting("center_text", DEFAULTS.center_text) then css = css .. " body { text-align: center; } " end
    if self.cfg:readSetting("use_anki_css", DEFAULTS.use_anki_css) and self.model then
        local user = self.model.css:gsub("@font%-face%s*%b{}", ""):gsub("@import[^;]*;", "")
        css = css .. user
    end
    return css
end

function ReviewScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local now, day_start, day_end = self:times()
    local new_limit, rev_limit = self:limits()
    local counts
    if self.practice then
        counts = _("Practice (not recorded)")
    elseif self.card_ids then
        counts = string.format(_("List %d / %d"), math.min(self.qpos, #self.card_ids), #self.card_ids)
    else
        local n, l, r = self.store:counts(self.ids, now, day_end, day_start, new_limit, rev_limit, LEARN_AHEAD)
        counts = string.format("N %d  L %d  R %d", n, l, r)
    end
    local shown_html = self.card and (self.showing_answer and self.a_html or self.q_html) or ""
    local images = {}
    for file in shown_html:gmatch('<img src="([^"]+)"') do images[#images + 1] = file end

    local top = ButtonTable:new{
        width = w, zero_sep = true, show_parent = self,
        buttons = { {
            { text = _("Undo"), enabled = #self.undo_stack > 0, callback = function() self:undo() end },
            { text = counts, enabled = false },
            { text = _("Zoom"), enabled = #images > 0, callback = function() self:zoom(images) end },
            { text = _("Options"), callback = function() self.plugin:showOptions(self) end },
            { text = _("Close"), callback = function() self:onClose() end },
        } },
    }

    local bottom
    if not self.card then
        bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self,
            buttons = { { { text = _("Close"), callback = function() self:onClose() end } } } }
    elseif not self.showing_answer then
        bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self,
            buttons = { { { text = _("Show answer"), callback = function() self:showAnswer() end } } } }
    elseif self.practice then
        bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self,
            buttons = { { { text = _("Continue"), callback = function() self:endPractice() end } } } }
    else
        local function btn(label, g)
            local res = self.preview[g]
            return { text = label .. "\n" .. FSRS.label(math.max(res.due - now, 60), res.state == 2),
                callback = function() self:answer(g) end }
        end
        local row
        if self.cfg:readSetting("pass_fail", DEFAULTS.pass_fail) then
            row = { btn(_("Fail"), 1), btn(_("Pass"), 3) }
        else
            row = { btn(_("Again"), 1), btn(_("Hard"), 2), btn(_("Good"), 3), btn(_("Easy"), 4) }
        end
        bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self, buttons = { row } }
    end

    local body_h = h - top:getSize().h - bottom:getSize().h
    local html
    if self.card then
        html = self.showing_answer and self.a_html or self.q_html
    else
        html = "<h2>" .. _("All done for now") .. "</h2><p>" .. _("No more cards are due in this deck.") .. "</p>"
    end
    html = (html:gsub('(<img src="([^"]+)"/>)', '<a href="afsimg:%2">%1</a>'))
    local font_px = Screen:scaleBySize(self.cfg:readSetting("font_size", DEFAULTS.font_size))
    if self.html_widget and self.html_widget.free then pcall(function() self.html_widget:free() end) end
    self.html_widget = ScrollHtmlWidget:new{
        html_body = '<div class="card">' .. html .. "</div>",
        css = self:css(),
        default_font_size = font_px,
        width = w - Screen:scaleBySize(24),
        height = body_h - Screen:scaleBySize(16),
        dialog = self,
        html_resource_directory = MEDIA_DIR,
        html_link_tapped_callback = function(link)
            local uri = type(link) == "table" and link.uri or link
            if type(uri) == "string" and uri:find("^afsimg:") then self:zoomImage(uri:sub(8)) end
        end,
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        width = w, height = h,
        VerticalGroup:new{
            align = "left",
            top,
            FrameContainer:new{ bordersize = 0, padding = Screen:scaleBySize(8), padding_left = Screen:scaleBySize(12),
                padding_right = Screen:scaleBySize(12), self.html_widget },
            bottom,
        },
    }
    -- e-ink comfort: a flashing full refresh every N answered cards clears ghosting
    local every = self.cfg:readSetting("refresh_every", DEFAULTS.refresh_every)
    local mode = "partial"
    if every > 0 and self.answered > 0 and self.answered % every == 0 and not self.showing_answer and not self.did_refresh then
        mode = "full"; self.did_refresh = true
    elseif self.showing_answer or self.answered % math.max(every, 1) ~= 0 then
        self.did_refresh = false
    end
    UIManager:setDirty(self, function() return mode, self.dimen end)
end

function ReviewScreen:showAnswer()
    if not self.card or self.showing_answer then return end
    self.showing_answer = true
    self:build()
end

function ReviewScreen:answer(rating)
    if not self.card or self.practice then return end
    local now, _ds, day_end, ro = self:times()
    local secs = math.min(math.max(C.now_precise() - (self.shown_at or now), 0), 120)
    local card = self.card
    local res = self.fsrs:preview(card, now, ro)[rating]
    local rid, lapses = self.store:saveAnswer(card, res, rating, now, ro, secs)
    local entry = { kind = "answer", card = card, revlog_id = rid, qpos = self.qpos }
    local msg
    local threshold = self.cfg:readSetting("leech_threshold", DEFAULTS.leech_threshold)
    if card.state == 2 and rating == 1 and threshold > 0 and lapses >= threshold and (card.leech or 0) == 0 then
        self.store:markLeech(card.id)
        msg = string.format(_("Leech! Suspended after %d lapses. Find it under Browse → Leeches."), lapses)
    end
    if self.cfg:readSetting("bury_siblings", DEFAULTS.bury_siblings) then
        local sib = self.store:siblingIds(card.nid, card.id, now)
        self.store:bury(sib, day_end)
        entry.buried_ids = sib
    end
    table.insert(self.undo_stack, entry)
    if #self.undo_stack > 30 then table.remove(self.undo_stack, 1) end
    self.answered = self.answered + 1
    if msg then self.plugin:toast(msg, 3) end
    if rating == 1 and self.cfg:readSetting("repeat_on_fail", DEFAULTS.repeat_on_fail) then
        self:startPractice(card)
    else
        self:loadNext()
    end
end

-- After Fail/Again the same card comes straight back for the learner's own practice.
-- Only the first rating was recorded; this second look changes nothing.
function ReviewScreen:startPractice(card)
    self.practice, self.showing_answer = true, false
    self.card = card
    self.shown_at = C.now_precise()
    self:build()
end

function ReviewScreen:endPractice()
    self.practice = false
    self:loadNext()
end

function ReviewScreen:zoomImage(file)
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then return self.plugin:toast(_("Image viewer is not available on this KOReader version.")) end
    UIManager:show(ImageViewer:new{ file = MEDIA_DIR .. "/" .. file, fullscreen = true, with_title_bar = false })
end

function ReviewScreen:zoom(images)
    if #images == 1 then return self:zoomImage(images[1]) end
    local dlg
    local rows = {}
    for i, file in ipairs(images) do
        rows[#rows + 1] = { { text = string.format(_("Image %d"), i), callback = function() UIManager:close(dlg); self:zoomImage(file) end } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dlg) end } }
    dlg = ButtonDialog:new{ title = _("Zoom which image?"), buttons = rows }
    UIManager:show(dlg)
end

function ReviewScreen:undo()
    local e = table.remove(self.undo_stack)
    if not e then return end
    if e.qpos then self.qpos = e.qpos end
    if e.kind == "bury" then self.store:unbury(e.ids)
    elseif e.kind == "suspend" then self.store:setSuspended(e.card.id, false)
    else self.store:undo(e); self.answered = math.max(self.answered - 1, 0) end
    self:present(self.store:cardById(e.card.id))
end

function ReviewScreen:suspend()
    if not self.card then return end
    self.store:setSuspended(self.card.id, true)
    table.insert(self.undo_stack, { kind = "suspend", card = self.card, qpos = self.qpos })
    self.plugin:toast(_("Card suspended."), 1)
    self:loadNext()
end

function ReviewScreen:buryCard()
    if not self.card then return end
    local _n, _ds, day_end = self:times()
    self.store:bury({ self.card.id }, day_end)
    table.insert(self.undo_stack, { kind = "bury", card = self.card, ids = { self.card.id }, qpos = self.qpos })
    self.plugin:toast(_("Card skipped until tomorrow."), 1)
    self:loadNext()
end

function ReviewScreen:refreshCurrent()
    if self.card then self:present(self.store:cardById(self.card.id)) end
end

function ReviewScreen:keyAnswer(kind)
    if not self.card then return true end
    if not self.showing_answer then self:showAnswer(); return true end
    if self.practice then self:endPractice(); return true end
    self:answer(kind == "pass" and 3 or 1)
    return true
end

-- "next page" button: reveal, then Pass/Good.   "previous page" button: reveal, then Fail/Again.
function ReviewScreen:onAdvance()
    return self:keyAnswer(self.cfg:readSetting("swap_keys", DEFAULTS.swap_keys) and "fail" or "pass")
end

function ReviewScreen:onRewind()
    return self:keyAnswer(self.cfg:readSetting("swap_keys", DEFAULTS.swap_keys) and "pass" or "fail")
end

function ReviewScreen:onClose()
    UIManager:close(self)
    return true
end

function ReviewScreen:onCloseWidget()
    if self.html_widget and self.html_widget.free then pcall(function() self.html_widget:free() end) end
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "full")
    local plugin, eaten = self.plugin, self.answered or 0
    if eaten >= 5 and plugin.settings:readSetting("pet_enabled", DEFAULTS.pet_enabled)
        and plugin.settings:readSetting("pet_after_session", DEFAULTS.pet_after_session) then
        UIManager:nextTick(function() plugin:showPet({ animate = true, session = eaten }) end)
    end
end

---------------------------------------------------------------------------------------------
-- Plugin
---------------------------------------------------------------------------------------------
local AnkiFSRS = WidgetContainer:extend{ name = "ankifsrs", is_doc_only = false }

function AnkiFSRS:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ankifsrs.lua")
    Dispatcher:registerAction("ankifsrs_study", {
        category = "none", event = "AnkiFsrsStudy", title = _("Anki FSRS: study"), general = true })
    self.ui.menu:registerToMainMenu(self)
end

function AnkiFSRS:onAnkiFsrsStudy() self:showDecks(); return true end

function AnkiFSRS:getStore()
    if not self.store then
        lfs.mkdir(DATA_DIR)
        self.store = Store.open(DATA_DIR .. "/ankifsrs.sqlite3")
    end
    return self.store
end

-- Maximum interval, shortened so that nothing is scheduled beyond the exam date (if one is set).
function AnkiFSRS:effectiveMaxInterval()
    local s = self.settings
    local max_ivl = s:readSetting("max_interval", DEFAULTS.max_interval)
    local y, m, d = tostring(s:readSetting("exam_date", "")):match("^(%d+)%-(%d+)%-(%d+)$")
    if y then
        local ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
        local days = FSRS.daysBetween(os.time(), ts, s:readSetting("rollover", DEFAULTS.rollover))
        if days >= 1 then max_ivl = math.min(max_ivl, math.max(days - 1, 1)) end
    end
    return max_ivl
end

function AnkiFSRS:getFsrs(retention_override)
    local s = self.settings
    local w = s:readSetting("weights")
    return FSRS.new{
        w = (type(w) == "table" and #w >= 19) and w or nil,
        retention = retention_override or s:readSetting("retention", DEFAULTS.retention),
        max_interval = self:effectiveMaxInterval(),
        learning_steps = C.parse_steps(s:readSetting("learning_steps", DEFAULTS.learning_steps)),
        relearning_steps = C.parse_steps(s:readSetting("relearning_steps", DEFAULTS.relearning_steps)),
    }
end

-- Desired retention set on a deck (or its nearest ancestor); nil when none is set
function AnkiFSRS:retentionForName(name)
    local store = self:getStore()
    while name and name ~= "" do
        local r = store:deckOpts(name).retention
        if r then return r, name end
        name = name:match("^(.*)::[^:]*$")
    end
    return nil
end

function AnkiFSRS:retentionForDeck(did)
    local name = self:getStore():deckNameById(did)
    return name and (self:retentionForName(name)) or nil
end

-- Daily limits for a deck: its own override if set, else the global settings
function AnkiFSRS:limitsFor(deck_name)
    local nl, rl = self:getStore():deckLimits(deck_name)
    return nl or self.settings:readSetting("new_per_day", DEFAULTS.new_per_day),
        rl or self.settings:readSetting("reviews_per_day", DEFAULTS.reviews_per_day)
end

-- Rendered question/answer HTML for a card: q_html, a_html, model, content   (nil if the note/model is missing)
function AnkiFSRS:renderCard(card)
    local store = self:getStore()
    local content = store:cardContent(card)
    if not content or not content.model then return nil end
    self.model_cache = self.model_cache or {}
    local m = self.model_cache[content.mid]
    if not m then
        m = { name = content.model[1], kind = content.model[2], css = content.model[5] or "" }
        m.fields = JSON.decode(content.model[3]); m.tmpls = JSON.decode(content.model[4])
        self.model_cache[content.mid] = m
    end
    local lookup = function(name) return store:mediaFile(name) end
    local q, a = Render.render(m, Apkg.split_fields(content.flds), content.tags, content.deck, card.ord)
    return Render.rewrite_images(q, lookup), Render.rewrite_images(a, lookup), m, content
end

function AnkiFSRS:set(key, value) self.settings:saveSetting(key, value); self.settings:flush() end

function AnkiFSRS:spin(title, key, min, max, step, on_done)
    return function()
        UIManager:show(SpinWidget:new{
            title_text = title, value = self.settings:readSetting(key, DEFAULTS[key]),
            value_min = min, value_max = max, value_step = step or 1, value_hold_step = (step or 1) * 10,
            default_value = DEFAULTS[key], ok_text = _("Set"),
            callback = function(spin) self:set(key, spin.value); if on_done then on_done() end end,
        })
    end
end

function AnkiFSRS:textInput(title, current, hint, on_save, multiline)
    local dlg
    dlg = InputDialog:new{
        title = title, input = current, input_hint = hint, allow_newline = multiline or false,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = not multiline, callback = function()
                local text = dlg:getInputText(); UIManager:close(dlg); on_save(text) end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function AnkiFSRS:toast(text, timeout) UIManager:show(InfoMessage:new{ text = text, timeout = timeout }) end

-- Run fn; if it fails show the error instead of letting KOReader crash
function AnkiFSRS:safeCall(fn, label)
    local ok, err = pcall(fn)
    if not ok then
        logger.err("ankifsrs error in " .. tostring(label) .. ": " .. tostring(err))
        pcall(function() self:toast(string.format("Anki FSRS error (%s):\n%s", tostring(label), tostring(err)), 10) end)
    end
end

function AnkiFSRS:study(deck_name, after_close, card_ids)
    UIManager:show(ReviewScreen:new{ plugin = self, deck_name = deck_name, on_close = after_close, card_ids = card_ids })
end

function AnkiFSRS:importDialog()
    local start = G_reader_settings:readSetting("home_dir") or "/mnt/us"
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = start,
        file_filter = function(name) return name:lower():match("%.apkg$") ~= nil end,
        onConfirm = function(path) self:importFile(path) end,
    })
end

function AnkiFSRS:importFile(path)
    local info = InfoMessage:new{ text = _("Importing deck… this can take a few minutes for big decks."), }
    UIManager:show(info)
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.3, function()
        local store = self:getStore()
        local ok, res, err = pcall(Apkg.import, path, store, {
            media_dir = MEDIA_DIR, tmp_dir = DATA_DIR .. "/tmp",
            rollover = self.settings:readSetting("rollover", DEFAULTS.rollover),
        })
        UIManager:close(info)
        if not ok or not res then pcall(function() store.conn:exec("ROLLBACK") end) end
        if not ok then
            logger.err("ankifsrs import failed:", res)
            return self:toast(_("Import failed:\n") .. tostring(res))
        end
        if not res then return self:toast(_("Import failed:\n") .. tostring(err)) end
        self.model_cache = nil
        local extra = ""
        if res.fsrs then
            if not self.settings:readSetting("weights") then
                local w = FSRS.normalizeParams(res.fsrs)
                if w then self:set("weights", w); extra = "\n" .. _("FSRS parameters from your Anki deck were applied.") end
            else
                extra = "\n" .. _("This deck contains FSRS parameters; your saved ones were kept.")
            end
        end
        self:toast(string.format(_("Imported %d new notes, %d cards (%d new), %d images, %d past reviews."),
            res.notes, res.cards, res.new_cards, res.media, res.revlog or 0) .. extra)
    end)
end

function AnkiFSRS:exportRevlog()
    local dir = DATA_DIR .. "/export"
    lfs.mkdir(dir)
    local path = dir .. "/revlog-" .. os.date("%Y%m%d-%H%M") .. ".jsonl"
    local n = self:getStore():exportRevlog(JSON, path)
    if n then self:toast(string.format(_("Exported %d reviews to:\n%s"), n, path))
    else self:toast(_("Could not write the export file.")) end
end

function AnkiFSRS:settingsMenu()
    local s = self.settings
    local function check(label, key)
        return { text = label, checked_func = function() return s:readSetting(key, DEFAULTS[key]) end,
            callback = function() self:set(key, not s:readSetting(key, DEFAULTS[key])) end }
    end
    return {
        { text = _("All options (dialog)…"), keep_menu_open = true, callback = function() self:showOptions(nil) end },
        { text = _("New cards per day"), keep_menu_open = true, callback = self:spin(_("New cards per day"), "new_per_day", 0, 9999) },
        { text = _("Maximum reviews per day"), keep_menu_open = true, callback = self:spin(_("Maximum reviews per day"), "reviews_per_day", 0, 9999) },
        { text = _("Desired retention"), keep_menu_open = true, callback = function() self:retentionDialog() end },
        { text = _("Presets (retention + steps)"), keep_menu_open = true, callback = function() self:presetDialog() end },
        { text = _("Exam date (caps intervals)"), keep_menu_open = true, callback = function() self:examDialog() end },
        check(_("Pass / Fail buttons"), "pass_fail"),
        check(_("Swap page-turn buttons"), "swap_keys"),
        check(_("Bury sibling cards until tomorrow"), "bury_siblings"),
        check(_("Repeat card after Fail / Again"), "repeat_on_fail"),
        { text = _("Pet settings…"), keep_menu_open = true, callback = function() self:petSettings() end },
        { text = _("Night mode"), checked_func = function() return self:nightModeOn() end,
          callback = function() self:toggleNightMode() end },
        { text = _("Leech threshold (lapses, 0 = off)"), keep_menu_open = true, callback = self:spin(_("Leech threshold"), "leech_threshold", 0, 50) },
        { text = _("Full screen refresh every N cards (0 = never)"), keep_menu_open = true, callback = self:spin(_("Refresh every N cards"), "refresh_every", 0, 100) },
        { text = _("Optimise FSRS parameters on this device"), keep_menu_open = true, callback = function() self:optimize() end },
        { text = _("FSRS parameters: restore previous"), keep_menu_open = true, callback = function() self:restoreParams() end },
        { text = _("FSRS parameters: load from file"), keep_menu_open = true, callback = function() self:loadParamsFile() end },
        { text = _("FSRS parameters: type / reset"), keep_menu_open = true, callback = function()
            local w = s:readSetting("weights")
            self:textInput(_("FSRS parameters (21 numbers; empty = defaults)"), w and table.concat(w, ", ") or "",
                _("21 comma-separated numbers"), function(t) self:applyParamText(t) end)
        end },
        { text = _("Learning steps (minutes)"), keep_menu_open = true, callback = function()
            self:textInput(_("Learning steps in minutes"), s:readSetting("learning_steps", DEFAULTS.learning_steps), "1 10",
                function(t) self:set("learning_steps", t) end)
        end },
        { text = _("Relearning steps (minutes)"), keep_menu_open = true, callback = function()
            self:textInput(_("Relearning steps in minutes"), s:readSetting("relearning_steps", DEFAULTS.relearning_steps), "10",
                function(t) self:set("relearning_steps", t) end)
        end },
        { text = _("Maximum interval (days)"), keep_menu_open = true, callback = self:spin(_("Maximum interval (days)"), "max_interval", 30, 36500, 30) },
        { text = _("Day starts at (hour)"), keep_menu_open = true, callback = self:spin(_("Day starts at (hour)"), "rollover", 0, 12) },
        { text = _("Card font size"), keep_menu_open = true, callback = self:spin(_("Card font size"), "font_size", 10, 60) },
        check(_("Center card text"), "center_text"),
        check(_("Use card styling from Anki"), "use_anki_css"),
    }
end

function AnkiFSRS:addToMainMenu(menu_items)
    menu_items.ankifsrs = {
        text = _("Anki FSRS"),
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = _("Study"), callback = function() self:showDecks() end },
            { text = _("Import .apkg"), callback = function() self:importDialog() end },
            { text = _("Pet"), callback = function() self:showPet() end },
            { text = _("Browse cards"), callback = function() self:showBrowse(nil) end },
            { text = _("Statistics & forecast"), callback = function() self:showStats() end },
            { text = _("Export review log"), callback = function() self:exportRevlog() end },
            { text = _("Settings"), sub_item_table_func = function() return self:settingsMenu() end },
        },
    }
end

function AnkiFSRS:onCloseWidget()
    if self.store then self.store:close(); self.store = nil end
end

require("afs_extras")(AnkiFSRS, { ReviewScreen = ReviewScreen })
require("afs_extras2")(AnkiFSRS, { ReviewScreen = ReviewScreen })

-- Wrap UI entry points so that an unexpected error is shown as a message (and logged) rather than crashing KOReader
local unpack = table.unpack or unpack
local function guard(cls, names)
    for _i, name in ipairs(names) do
        local orig = cls[name]
        if orig then
            cls[name] = function(self, ...)
                local args = { n = select("#", ...), ... }
                local ok, res = pcall(function() return orig(self, unpack(args, 1, args.n)) end)
                if not ok then
                    logger.err("ankifsrs error in " .. name .. ": " .. tostring(res))
                    local plugin = self.plugin or self
                    pcall(function() plugin:toast(string.format("Anki FSRS error (%s):\n%s", name, tostring(res)), 10) end)
                    return nil
                end
                return res
            end
        end
    end
end
guard(AnkiFSRS, { "showDecks", "showBrowse", "showBrowseResults", "showStats", "showOptions", "showMoreSettings",
    "showCardInfo", "editNote", "optimize", "optimizeFinished", "deckMenu", "deckLimitsDialog", "deckSettingsDialog", "toggleNightMode", "importDialog",
    "exportRevlog", "loadParamsFile", "retentionDialog", "examDialog", "presetDialog", "frontlight", "toggleLight",
    "restoreParams", "study", "applyParamText", "showPet", "petSettings", "showBadges", "previewCards",
    "readThroughDeck", "previewNewCards", "zoomImage" })
guard(ReviewScreen, { "loadNext", "present", "build", "showAnswer", "answer", "undo", "suspend", "buryCard",
    "refreshCurrent", "keyAnswer", "startPractice", "endPractice", "zoom", "zoomImage", "nextFromList" })

return AnkiFSRS
