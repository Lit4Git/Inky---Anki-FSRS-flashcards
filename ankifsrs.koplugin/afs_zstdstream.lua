-- Streaming zstd decompression via libzstd. Anki writes zstd frames WITHOUT a stored content size,
-- which KOReader's single-shot ffi/zstd helper cannot handle, so we drive ZSTD_decompressStream ourselves.
local ffi = require("ffi")

local M = {}
local lib

local function declare(src) pcall(ffi.cdef, src) end

local function load_lib()
    if lib then return lib end
    declare("typedef struct { const void *src; size_t size; size_t pos; } ankifsrs_zin;")
    declare("typedef struct { void *dst; size_t size; size_t pos; } ankifsrs_zout;")
    declare("void* ZSTD_createDCtx(void);")
    declare("size_t ZSTD_freeDCtx(void* dctx);")
    declare("size_t ZSTD_decompressStream(void* zds, void* output, void* input);")
    declare("unsigned ZSTD_isError(size_t code);")
    declare("const char* ZSTD_getErrorName(size_t code);")
    local names = { "libs/libzstd.so.1", "libzstd.so.1", "libs/libzstd.so", "libzstd.so", "zstd", "libzstd.1.dylib" }
    local errs = {}
    for _, n in ipairs(names) do
        local ok, l = pcall(ffi.load, n)
        if ok then
            local ok2 = pcall(function() return l.ZSTD_decompressStream, l.ZSTD_createDCtx, l.ZSTD_isError end)
            if ok2 then lib = l; return lib end
            errs[#errs + 1] = n .. ": missing symbols"
        else
            errs[#errs + 1] = tostring(l)
        end
    end
    error("libzstd not found (" .. table.concat(errs, "; ") .. ")")
end

function M.decompress(data)
    local z = load_lib()
    local dctx = z.ZSTD_createDCtx()
    if dctx == nil then error("ZSTD_createDCtx failed") end
    local CHUNK = 1024 * 1024
    local outbuf = ffi.new("uint8_t[?]", CHUNK)
    local inb, outb = ffi.new("ankifsrs_zin[1]"), ffi.new("ankifsrs_zout[1]")
    inb[0].src, inb[0].size, inb[0].pos = data, #data, 0
    outb[0].dst, outb[0].size = outbuf, CHUNK
    local pin, pout = ffi.cast("void*", inb), ffi.cast("void*", outb)
    local parts, err = {}, nil
    while true do
        outb[0].pos = 0
        local ret = z.ZSTD_decompressStream(dctx, pout, pin)
        if z.ZSTD_isError(ret) ~= 0 then err = ffi.string(z.ZSTD_getErrorName(ret)); break end
        local produced = tonumber(outb[0].pos)
        if produced > 0 then parts[#parts + 1] = ffi.string(outbuf, produced) end
        local consumed_all = tonumber(inb[0].pos) >= tonumber(inb[0].size)
        if tonumber(ret) == 0 and consumed_all then break end            -- frame finished, nothing left
        if consumed_all and produced < CHUNK and tonumber(ret) ~= 0 then  -- needs more input that isn't there
            err = "truncated zstd data"; break
        end
    end
    pcall(z.ZSTD_freeDCtx, dctx)
    if err then error(err) end
    return table.concat(parts)
end

return M
