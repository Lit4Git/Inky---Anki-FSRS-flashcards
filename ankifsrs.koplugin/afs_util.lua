-- Small pure-Lua helpers (no KOReader dependencies).
local U = {}

-- Keep at most n UTF-8 characters
function U.truncate(s, n)
    local out, count = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then out[#out + 1] = "…"; break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

function U.html_to_text(h)
    h = h or ""
    h = h:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", ""):gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", "")
    h = h:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Dd][Ii][Vv]>", "\n"):gsub("</[Pp]>", "\n"):gsub("</[Ll][Ii]>", ""):gsub("<[Ll][Ii][^>]*>", "\n• ")
    h = h:gsub("<[^>]*>", "")
    h = h:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
    h = h:gsub("\n%s*\n%s*\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return h
end

function U.one_line(h, n)
    local t = U.html_to_text(h):gsub("%s+", " ")
    return U.truncate(t, n or 70)
end

function U.split_name(name)
    local parts = {}
    for part in (name .. "::"):gmatch("(.-)::") do parts[#parts + 1] = part end
    return parts
end

function U.bar(n, max, width)
    if max <= 0 or n <= 0 then return "" end
    return string.rep("#", math.max(1, math.floor(n / max * width + 0.5)))
end

function U.duration(sec)
    sec = math.floor(sec + 0.5)
    if sec < 90 then return string.format("%d s", sec) end
    if sec < 5400 then return string.format("%d min", math.floor(sec / 60 + 0.5)) end
    return string.format("%.1f h", sec / 3600)
end

function U.pct(v) return v and string.format("%.0f%%", v) or "–" end

function U.date(ts) return ts and ts > 0 and os.date("%Y-%m-%d", ts) or "–" end

return U
