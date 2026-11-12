-- Shared constants and helpers for the Anki FSRS plugin.
local DataStorage = require("datastorage")
local _ = require("gettext")

local C = {}

C.PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
C.PET_DIR = C.PLUGIN_DIR .. "/pet"
C.DATA_DIR = DataStorage:getDataDir() .. "/ankifsrs"
C.MEDIA_DIR = C.DATA_DIR .. "/media"
C.LEARN_AHEAD = 20 * 60

C.DEFAULTS = {
    new_per_day = 20, reviews_per_day = 200, retention = 0.9, max_interval = 36500,
    learning_steps = "1 10", relearning_steps = "10", font_size = 22, center_text = true,
    use_anki_css = false, rollover = 4, pass_fail = false, swap_keys = false, exam_date = "",
    leech_threshold = 8, refresh_every = 10, review_order = "due", new_order = "pos", bury_siblings = false, repeat_on_fail = true,
    pet_enabled = true, pet_name = "Munch", pet_goal = 20, pet_mode = "gentle", pet_after_session = true,
}

C.PRESETS = {
    { name = _("Balanced – 90% retention"), retention = 0.90, learning_steps = "1 10", relearning_steps = "10" },
    { name = _("Exam prep – 95% retention"), retention = 0.95, learning_steps = "1 10", relearning_steps = "10" },
    { name = _("Cram – 97% retention, short steps"), retention = 0.97, learning_steps = "1 10 60", relearning_steps = "10 30" },
    { name = _("Light – 85% retention"), retention = 0.85, learning_steps = "1 10", relearning_steps = "10" },
}

C.REVIEW_ORDERS = { due = _("Oldest due first"), random = _("Random"), overdue = _("Most overdue first") }
C.NEW_ORDERS = { pos = _("In deck order"), random = _("Random") }

function C.parse_steps(str)
    local steps = {}
    for tok in tostring(str):gmatch("%S+") do
        local n = tonumber(tok:match("^[%d%.]+") or "")
        if n and n > 0 then
            local unit = tok:match("[%a]+$")
            if unit == "h" then n = n * 60 elseif unit == "d" then n = n * 1440 end
            steps[#steps + 1] = n
        end
    end
    return steps
end

local ok, futil = pcall(require, "ffi/util")
function C.now_precise()
    if ok and futil.gettime then
        local s, u = futil.gettime()
        return s + u / 1e6
    end
    return os.time()
end

return C
