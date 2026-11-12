-- Minimal protobuf wire-format reader (enough for Anki's package/notetype blobs).
local PB = {}

function PB.varint(s, pos)
    local result, shift = 0, 0
    while true do
        local b = s:byte(pos)
        if not b then return nil, pos end
        pos = pos + 1
        result = result + (b % 128) * (2 ^ shift)
        if b < 128 then return result, pos end
        shift = shift + 7
    end
end

-- returns a list of { n = field_number, w = wire_type, v = number|string }
function PB.decode(s)
    local out, pos = {}, 1
    if type(s) ~= "string" then return out end
    while pos <= #s do
        local key
        key, pos = PB.varint(s, pos)
        if not key then break end
        local n, w = math.floor(key / 8), key % 8
        local v
        if w == 0 then
            v, pos = PB.varint(s, pos)
        elseif w == 2 then
            local len
            len, pos = PB.varint(s, pos)
            if not len then break end
            v = s:sub(pos, pos + len - 1); pos = pos + len
        elseif w == 1 then v = s:sub(pos, pos + 7); pos = pos + 8
        elseif w == 5 then v = s:sub(pos, pos + 3); pos = pos + 4
        else break end
        out[#out + 1] = { n = n, w = w, v = v }
    end
    return out
end

-- little-endian IEEE754 float32 at string position i (nil for NaN/inf)
function PB.f32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    if not b4 then return nil end
    local sign = (b4 >= 128) and -1 or 1
    local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
    local mant = (b3 % 128) * 65536 + b2 * 256 + b1
    if exp == 255 then return nil end
    if exp == 0 then return sign * mant * 2 ^ -149 end
    return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function plausible_params(w)
    if #w ~= 21 and #w ~= 19 then return false end
    for _, v in ipairs(w) do if v < -50 or v > 200 then return false end end
    if w[1] <= 0 or w[2] <= 0 or w[3] <= 0 or w[4] <= 0 then return false end
    if #w == 21 and (w[21] < 0.05 or w[21] > 1) then return false end
    return true
end
PB.plausible_params = plausible_params

-- Look through a DeckConfig protobuf blob for a packed list of 21 (FSRS-6) or 19 (FSRS-5) floats.
function PB.fsrs_params(config)
    local best
    for _, fld in ipairs(PB.decode(config)) do
        if fld.w == 2 and (#fld.v == 84 or #fld.v == 76) then
            local w, ok = {}, true
            for i = 1, #fld.v / 4 do
                local v = PB.f32(fld.v, (i - 1) * 4 + 1)
                if v == nil then ok = false; break end
                w[i] = v
            end
            if ok and plausible_params(w) and (not best or #w > #best) then best = w end
        end
    end
    return best
end

function PB.first(fields, n)
    for _, f in ipairs(fields) do if f.n == n then return f.v end end
end

return PB
