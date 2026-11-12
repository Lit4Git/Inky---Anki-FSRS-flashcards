-- Pet (card-eating monster) and deck read-through screens for Anki FSRS.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local Screen = Device.screen

local FSRS = require("afs_fsrs")
local Pet = require("afs_pet")
local C = require("afs_common")
local U = require("afs_util")
local D = C.DEFAULTS

return function(AnkiFSRS, _env)

local MOOD_LABEL = { full = _("fed"), idle = _("nibbling"), hungry = _("hungry"), sleepy = _("sleeping"), tomb = _("gone") }
local MODE_LABEL = { gentle = _("Gentle"), care = _("Needs care"), hardcore = _("Hardcore") }

local function day_info(self)
    local now = os.time()
    local ro = self.settings:readSetting("rollover", D.rollover)
    local day_start = FSRS.dayStart(now, ro)
    local phase = day_start % 86400
    return now, day_start, phase, math.floor((day_start - phase) / 86400)
end

local CSS = [[
    @page { margin: 0; }
    body { margin: 0; padding: 0; text-align: center; }
    h2 { margin: 0.2em 0; }
    p { margin: 0.4em 0; }
    img { max-width: 100%; }
    a { color: inherit; text-decoration: none; }
]]

---------------------------------------------------------------------------------------------
-- Pet
---------------------------------------------------------------------------------------------
function AnkiFSRS:petName() return self.settings:readSetting("pet_name", D.pet_name) end

function AnkiFSRS:petState()
    local _now, _ds, phase, today = day_info(self)
    local daily = self:getStore():dailyCounts(phase)
    return Pet.compute(daily, today, {
        goal = self.settings:readSetting("pet_goal", D.pet_goal),
        mode = self.settings:readSetting("pet_mode", D.pet_mode),
        hardcore_since = self.settings:readSetting("pet_hardcore_since"),
    }), today
end

-- {status text, count text} for the deck list row; nil if the pet is off or anything goes wrong
function AnkiFSRS:petRow()
    if not self.settings:readSetting("pet_enabled", D.pet_enabled) then return nil end
    local ok, s = pcall(function() return (self:petState()) end)
    if not ok or not s then return nil end
    return string.format(_("Pet: %s (%s)"), self:petName(), MOOD_LABEL[s.mood] or ""), string.format("%d / %d", s.today, s.goal)
end

local PetScreen = InputContainer:extend{ covers_fullscreen = true, plugin = nil, animate = false, session = 0 }

function PetScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    local state, today = self.plugin:petState()
    self.state, self.today_idx = state, today
    self:build()
    if self.animate and state.mood ~= "tomb" and state.today > 0 then self:startAnimation() end
end

function PetScreen:sprite(name)
    local path = C.PET_DIR .. "/" .. name .. ".png"
    local ok, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if ok then
        local ok2, widget = pcall(function() return ImageWidget:new{ file = path, scale_factor = 1, alpha = false } end)
        if ok2 and widget then return widget end
    end
    return nil
end

function PetScreen:html()
    local s, st = self.plugin, self.state
    local name = s:petName()
    local lines = {}
    lines[#lines + 1] = string.format("<h2>%s the %s</h2>", name, st.stage_name)
    lines[#lines + 1] = string.format("<p>Today: <b>%d / %d</b> cards eaten<br/>%s</p>", st.today, st.goal, Pet.bar(st.today, st.goal, 20))
    if self.session and self.session > 0 then
        lines[#lines + 1] = string.format("<p>This session: <b>%d</b> cards eaten</p>", self.session)
    end
    local growth_line
    if st.next_stage_at then
        local prev = Pet.STAGE_FROM[st.stage]
        growth_line = string.format("Growth: %d / %d to %s<br/>%s", st.growth, st.next_stage_at, Pet.STAGE_NAMES[st.stage + 1],
            Pet.bar(st.growth - prev, st.next_stage_at - prev, 20))
    else
        growth_line = string.format("Fully grown! %d cards eaten in total.", st.total)
    end
    lines[#lines + 1] = "<p>" .. growth_line .. "</p>"
    lines[#lines + 1] = string.format("<p>Streak: <b>%d</b> day(s) (best %d)   Shields: <b>%d</b></p>", st.streak_now, st.best_streak, st.shields)
    if st.mode == "hardcore" then
        lines[#lines + 1] = string.format("<p>Hardcore mode. Lives lost: %d</p>", st.lives_lost)
    end
    lines[#lines + 1] = "<p><i>" .. Pet.message(st, name, self.today_idx) .. "</i></p>"
    if not self.sprite_ok then lines[#lines + 1] = "<p>(^_^)</p>" end
    return table.concat(lines)
end

function PetScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local plugin = self.plugin
    local top = ButtonTable:new{ width = w, zero_sep = true, show_parent = self, buttons = { {
        { text = _("Settings"), callback = function() plugin:petSettings(function() self:refresh() end) end },
        { text = _("Badges"), callback = function() plugin:showBadges() end },
        { text = _("Close"), callback = function() self:onClose() end },
    } } }
    local bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self, buttons = { {
        { text = _("Study now"), callback = function() self:onClose(); plugin:showDecks() end },
    } } }
    local sprite_name = self.frame or Pet.sprite(self.state)
    local sprite = self:sprite(sprite_name)
    self.sprite_ok = sprite ~= nil
    local CenterContainer = require("ui/widget/container/centercontainer")
    local sprite_h = 400
    local center = CenterContainer:new{ dimen = Geom:new{ w = w, h = sprite_h }, sprite or VerticalGroup:new{} }
    local text_h = h - top:getSize().h - bottom:getSize().h - sprite_h
    if self.text_widget and self.text_widget.free and not self.keep_text then pcall(function() self.text_widget:free() end) end
    if not self.keep_text or not self.text_widget then
        self.text_widget = ScrollHtmlWidget:new{
            html_body = '<div class="pet">' .. self:html() .. "</div>", css = CSS,
            default_font_size = Screen:scaleBySize(22), width = w - Screen:scaleBySize(24),
            height = text_h - Screen:scaleBySize(16), dialog = self,
        }
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0, width = w, height = h,
        VerticalGroup:new{ align = "center", top, center,
            FrameContainer:new{ bordersize = 0, padding = Screen:scaleBySize(8), self.text_widget }, bottom },
    }
    UIManager:setDirty(self, function() return self.frame and "fast" or "ui", self.dimen end)
end

function PetScreen:refresh()
    local state, today = self.plugin:petState()
    self.state, self.today_idx, self.keep_text = state, today, false
    self:build()
end

function PetScreen:startAnimation()
    local seq = { "eat1", "eat2", "eat1", "eat2" }
    local i = 0
    local function tick()
        if self.closed then return end
        i = i + 1
        self.keep_text = true
        if i <= #seq then
            self.frame = string.format("s%d_%s", self.state.stage, seq[i])
            self:build()
            UIManager:scheduleIn(0.7, tick)
        else
            self.frame = nil
            self:build()
        end
    end
    UIManager:scheduleIn(0.5, tick)
end

function PetScreen:onClose()
    self.closed = true
    UIManager:close(self)
    return true
end

function PetScreen:onCloseWidget()
    if self.text_widget and self.text_widget.free then pcall(function() self.text_widget:free() end) end
    UIManager:setDirty(nil, "full")
end

function AnkiFSRS:showPet(opts)
    opts = opts or {}
    UIManager:show(PetScreen:new{ plugin = self, animate = opts.animate, session = opts.session or 0 })
end

function AnkiFSRS:showBadges()
    local st = self:petState()
    local lines = { string.format(_("Total cards eaten: %d"), st.total), string.format(_("Best streak: %d day(s)"), st.best_streak),
        string.format(_("Most cards in a day: %d"), st.max_day), "" }
    for _i, b in ipairs(Pet.badges(st)) do lines[#lines + 1] = (b.earned and "[x] " or "[ ] ") .. b.text end
    if st.lives_lost > 0 then lines[#lines + 1] = ""; lines[#lines + 1] = string.format(_("Lives lost (hardcore): %d"), st.lives_lost) end
    UIManager:show(TextViewer:new{ title = _("Badges"), text = table.concat(lines, "\n"),
        width = Screen:getWidth() - Screen:scaleBySize(20), height = Screen:getHeight() - Screen:scaleBySize(80) })
end

function AnkiFSRS:petSettings(on_done)
    local s = self.settings
    local dlg
    local function act(fn) return function() UIManager:close(dlg); fn() end end
    local function again() if on_done then on_done() end; self:petSettings(on_done) end
    local mode = s:readSetting("pet_mode", D.pet_mode)
    local function set_mode(m)
        self:set("pet_mode", m)
        if m == "hardcore" then
            local _n, _ds, _p, today = day_info(self)
            self:set("pet_hardcore_since", today)       -- earlier missed days never count against the pet
        end
        again()
    end
    local rows = {
        { { text = _("Pet: ") .. (s:readSetting("pet_enabled", D.pet_enabled) and _("ON") or _("OFF")),
            callback = act(function() self:set("pet_enabled", not s:readSetting("pet_enabled", D.pet_enabled)); again() end) } },
        { { text = string.format(_("Name: %s"), self:petName()), callback = act(function()
            self:textInput(_("Name your pet"), self:petName(), "Munch", function(t)
                t = t:gsub("^%s+", ""):gsub("%s+$", "")
                if t ~= "" then self:set("pet_name", U.truncate(t, 16)) end
                again()
            end)
        end) } },
        { { text = string.format(_("Daily goal: %d cards"), s:readSetting("pet_goal", D.pet_goal)),
            callback = act(self:spin(_("Daily goal (cards)"), "pet_goal", 5, 500, 1, again)) } },
        { { text = string.format(_("Strictness: %s"), MODE_LABEL[mode] or mode), callback = act(function()
            local order = Pet.MODES
            local nxt = order[1]
            for i, m in ipairs(order) do if m == mode then nxt = order[i % #order + 1] end end
            if nxt == "hardcore" then
                UIManager:show(ConfirmBox:new{
                    text = _("Hardcore: if you miss 5 unprotected days in a row, your pet dies and starts again as an egg. Only days from now on count. Switch on?"),
                    ok_text = _("Switch on"), cancel_text = _("Cancel"), ok_callback = function() set_mode("hardcore") end })
            else
                set_mode(nxt)
            end
        end) } },
        { { text = _("Show after sessions: ") .. (s:readSetting("pet_after_session", D.pet_after_session) and _("ON") or _("OFF")),
            callback = act(function() self:set("pet_after_session", not s:readSetting("pet_after_session", D.pet_after_session)); again() end) } },
        { { text = _("Close"), callback = function() UIManager:close(dlg) end } },
    }
    dlg = ButtonDialog:new{
        title = _("Pet settings\nGentle: never dies, only sleeps. Needs care: looks weak after 3 missed days. Hardcore: dies after 5 missed days."),
        buttons = rows,
    }
    UIManager:show(dlg)
end

---------------------------------------------------------------------------------------------
-- Read-through (preview) of a list of cards: question and answer together, nothing is recorded
---------------------------------------------------------------------------------------------
local STATE_LABEL = { [0] = _("new"), [1] = _("learning"), [2] = _("review"), [3] = _("relearning") }

local PreviewScreen = InputContainer:extend{ covers_fullscreen = true, plugin = nil, card_ids = nil, index = 1 }

function PreviewScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.show_answers = true
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            Next = { { Device.input.group.PgFwd } },
            Prev = { { Device.input.group.PgBack } },
        }
    end
    self:load()
end

function PreviewScreen:load()
    local store = self.plugin:getStore()
    local card = store:cardById(self.card_ids[self.index])
    self.card = card
    self.q_html, self.a_html = nil, nil
    if card then self.q_html, self.a_html = self.plugin:renderCard(card) end
    self:build()
end

function PreviewScreen:combined()
    if not self.q_html then return "<p>" .. _("This card has no content.") .. "</p>" end
    if not self.show_answers then return self.q_html end
    local qt = U.html_to_text(self.q_html):sub(1, 30)
    local at = U.html_to_text(self.a_html)
    if qt ~= "" and at:find(qt, 1, true) then return self.a_html end      -- the answer side already repeats the question
    return self.q_html .. "<hr/>" .. self.a_html
end

function PreviewScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local n = #self.card_ids
    local card = self.card
    local label = card and ((card.suspended or 0) == 1 and _("suspended") or STATE_LABEL[card.state] or "") or ""
    local html = self:combined()
    local images = {}
    for file in html:gmatch('<img src="([^"]+)"') do images[#images + 1] = file end
    html = (html:gsub('(<img src="([^"]+)"/>)', '<a href="afsimg:%2">%1</a>'))

    local top = ButtonTable:new{ width = w, zero_sep = true, show_parent = self, buttons = { {
        { text = _("Close"), callback = function() self:onClose() end },
        { text = string.format("%d / %d  %s", self.index, n, label), enabled = false },
        { text = _("Zoom"), enabled = #images > 0, callback = function() self.plugin:zoomImage(images[1]) end },
        { text = _("Answers: ") .. (self.show_answers and _("shown") or _("hidden")),
          callback = function() self.show_answers = not self.show_answers; self:build() end },
    } } }
    local bottom = ButtonTable:new{ width = w, zero_sep = true, show_parent = self, buttons = { {
        { text = _("Previous"), enabled = self.index > 1, callback = function() self:onPrev() end },
        { text = _("Next"), enabled = self.index < n, callback = function() self:onNext() end },
    } } }
    local body_h = h - top:getSize().h - bottom:getSize().h
    if self.html_widget and self.html_widget.free then pcall(function() self.html_widget:free() end) end
    local cfg = self.plugin.settings
    self.html_widget = ScrollHtmlWidget:new{
        html_body = '<div class="card">' .. html .. "</div>",
        css = CSS:gsub("text%-align: center;", cfg:readSetting("center_text", D.center_text) and "text-align: center;" or "text-align: left;"),
        default_font_size = Screen:scaleBySize(cfg:readSetting("font_size", D.font_size)),
        width = w - Screen:scaleBySize(24), height = body_h - Screen:scaleBySize(16), dialog = self,
        html_resource_directory = C.MEDIA_DIR,
        html_link_tapped_callback = function(link)
            local uri = type(link) == "table" and link.uri or link
            if type(uri) == "string" and uri:find("^afsimg:") then self.plugin:zoomImage(uri:sub(8)) end
        end,
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0, width = w, height = h,
        VerticalGroup:new{ align = "left", top,
            FrameContainer:new{ bordersize = 0, padding = Screen:scaleBySize(8), self.html_widget }, bottom },
    }
    UIManager:setDirty(self, function() return "partial", self.dimen end)
end

function PreviewScreen:onNext()
    if self.index < #self.card_ids then self.index = self.index + 1; self:load()
    else self.plugin:toast(_("End of the list."), 1) end
    return true
end

function PreviewScreen:onPrev()
    if self.index > 1 then self.index = self.index - 1; self:load() end
    return true
end

function PreviewScreen:onClose() UIManager:close(self); return true end
function PreviewScreen:onCloseWidget()
    if self.html_widget and self.html_widget.free then pcall(function() self.html_widget:free() end) end
    UIManager:setDirty(nil, "full")
end

function AnkiFSRS:previewCards(ids, start)
    if not ids or #ids == 0 then return self:toast(_("No cards to show.")) end
    UIManager:show(PreviewScreen:new{ plugin = self, card_ids = ids, index = math.min(math.max(start or 1, 1), #ids) })
end

function AnkiFSRS:zoomImage(file)
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok then return self:toast(_("Image viewer is not available on this KOReader version.")) end
    UIManager:show(ImageViewer:new{ file = C.MEDIA_DIR .. "/" .. file, fullscreen = true, with_title_bar = false })
end

-- Convenience entry points for a deck (nil = all decks)
function AnkiFSRS:readThroughDeck(deck_name)
    local store = self:getStore()
    self:previewCards(store:cardIds(store:deckIds(deck_name)), 1)
end

function AnkiFSRS:previewNewCards(deck_name)
    local store = self:getStore()
    local ids = store:deckIds(deck_name)
    local now, day_start = day_info(self)
    local nl = self:limitsFor(deck_name)
    local left = math.max(0, nl - store:newToday(ids, day_start))
    local order = self.settings:readSetting("new_order", D.new_order) == "random" and "c.pos, c.id" or "c.pos, c.id"
    local list = store:cardIds(ids, "c.state = 0 AND c.suspended = 0", order, left)
    if #list == 0 then return self:toast(_("No new cards are due to be introduced today.")) end
    self:previewCards(list, 1)
end

end
