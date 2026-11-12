-- Anki card template renderer (fields, conditionals, cloze, common filters) -> HTML.
-- Pure Lua, no KOReader dependencies.

local R = {}

local function strip_html(s)
    s = s:gsub("<br%s*/?>", " "):gsub("<[^>]*>", ""):gsub("&nbsp;", " ")
    return s
end

local function is_empty(s)
    if not s then return true end
    return strip_html(s):match("^%s*$") ~= nil
end
R.strip_html = strip_html

-- {{c1::text::hint}} handling. `active` is the cloze number of this card.
local function render_cloze(text, active, answer_side)
    local function repl(n, body)
        local content, hint = body:match("^(.-)::(.*)$")
        if not content then content = body end
        n = tonumber(n)
        if n == active then
            if answer_side then return '<span class="cloze">' .. content .. "</span>" end
            return '<span class="cloze">[' .. ((hint and hint ~= "") and hint or "...") .. "]</span>"
        end
        return content
    end
    for _ = 1, 8 do                      -- innermost first (handles nesting)
        local new, n = text:gsub("{{c(%d+)::([^{}]-)}}", repl)
        text = new
        if n == 0 then break end
    end
    text = text:gsub("{{c(%d+)::(.-)}}", repl)  -- fallback for bodies containing braces
    return text
end
R.cloze = render_cloze

local function furigana(s, mode)
    return (s:gsub(" ?([^ >]-)%[(.-)%]", function(base, reading)
        if mode == "kanji" then return base end
        if mode == "kana" then return reading end
        return base .. "(" .. reading .. ")"
    end))
end

local function apply_filter(name, value, ctx)
    if name == "text" then return strip_html(value)
    elseif name == "cloze" then return render_cloze(value, ctx.cloze_ord, ctx.answer)
    elseif name == "hint" then
        if is_empty(value) then return "" end
        return '<div class="hint">(hint) ' .. value .. "</div>"
    elseif name == "type" then return ""
    elseif name == "furigana" or name == "kanji" or name == "kana" then return furigana(value, name)
    end
    return value                           -- unknown filters: pass through
end

-- ctx = { fields = {Name=value}, tags, deck, card_name, type_name, cloze_ord, answer, front }
local function expand(tpl, ctx)
    -- conditionals ({{#F}}..{{/F}}, {{^F}}..{{/F}}), repeated for nesting
    for _ = 1, 10 do
        local changed = false
        tpl = tpl:gsub("{{#([^{}]+)}}(.-){{/%1}}", function(name, body)
            changed = true
            local f = name:match("([^:]+)$")
            return (not is_empty(ctx.fields[f] or ctx.special[f])) and body or ""
        end)
        tpl = tpl:gsub("{{%^([^{}]+)}}(.-){{/%1}}", function(name, body)
            changed = true
            local f = name:match("([^:]+)$")
            return is_empty(ctx.fields[f] or ctx.special[f]) and body or ""
        end)
        if not changed then break end
    end
    tpl = tpl:gsub("{{([^{}]+)}}", function(key)
        key = key:gsub("^%s+", ""):gsub("%s+$", "")
        if key == "FrontSide" then return ctx.front or "" end
        local filters, field = {}, key
        while true do
            local f, rest = field:match("^([%w_]+):(.+)$")
            if not f then break end
            filters[#filters + 1] = f; field = rest
        end
        local value = ctx.fields[field]
        if value == nil then value = ctx.special[field] end
        if value == nil then return "[unknown field: " .. field .. "]" end
        for i = #filters, 1, -1 do value = apply_filter(filters[i], value, ctx) end
        return value
    end)
    return tpl
end

local function sanitize(html)
    html = html:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
    html = html:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", "")
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<[Ll][Ii][Nn][Kk][^>]*>", "")
    html = html:gsub("%[sound:[^%]]*%]", "")
    html = html:gsub('<hr id="?answer"?%s*/?>', "<hr/>")
    html = html:gsub("\\%((.-)\\%)", "%1"):gsub("\\%[(.-)\\%]", "%1")   -- MathJax: show raw TeX
    return html
end
R.sanitize = sanitize

-- model = { kind=0|1, fields={names}, tmpls={{name,qfmt,afmt}}, css, name }
-- Returns question_html, answer_html
function R.render(model, flds, tags, deck, ord)
    local fields = {}
    for i, name in ipairs(model.fields) do fields[name] = flds[i] or "" end
    local tmpl = model.tmpls[(model.kind == 1) and 1 or (ord + 1)] or model.tmpls[1]
    if not tmpl then return "(card template missing)", "(card template missing)" end
    local special = {
        Tags = tags or "", Deck = deck or "", Subdeck = (deck or ""):match("([^:]+)$") or "",
        Card = tmpl.name or "", Type = model.name or "", CardFlag = "",
    }
    local ctx = { fields = fields, special = special, cloze_ord = ord + 1, answer = false }
    local q = sanitize(expand(tmpl.qfmt or "", ctx))
    ctx.answer, ctx.front = true, q
    local a = sanitize(expand(tmpl.afmt or "", ctx))
    return q, a
end

-- Rewrite <img src> through a lookup (name -> safe file); missing images become alt text.
function R.rewrite_images(html, lookup)
    return (html:gsub("<[Ii][Mm][Gg]([^>]*)>", function(attrs)
        local src = attrs:match('[Ss][Rr][Cc]%s*=%s*"([^"]*)"') or attrs:match("[Ss][Rr][Cc]%s*=%s*'([^']*)'")
            or attrs:match("[Ss][Rr][Cc]%s*=%s*([^%s>]+)")
        if not src then return "" end
        local name = src:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        local file = lookup(name) or lookup(src)
        if file then return '<img src="' .. file .. '"/>' end
        return "[image: " .. name .. "]"
    end))
end

return R
