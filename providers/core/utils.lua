-- utils.lua — generic helpers

local M = {}

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"
local TMPDIR = IS_WIN
    and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
    or  (os.getenv("TMPDIR") or "/tmp")

-- ── tmp file ───────────────────────────────────────────────
function M.tmpfile(suffix)
    math.randomseed(os.time())
    local stamp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    return TMPDIR .. SEP .. "ai_" .. stamp .. (suffix or ".tmp")
end

-- ── write file ─────────────────────────────────────────────
function M.write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content); f:close()
end

-- ── JSON helpers ───────────────────────────────────────────
function M.json_str(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        local b = c:byte()
        if     c == '\\'  then out[#out+1] = '\\\\'
        elseif c == '"'   then out[#out+1] = '\\"'
        elseif c == '\n'  then out[#out+1] = '\\n'
        elseif c == '\r'  then out[#out+1] = '\\r'
        elseif c == '\t'  then out[#out+1] = '\\t'
        elseif b < 32     then out[#out+1] = string.format('\\u%04x', b)
        else                   out[#out+1] = c
        end
    end
    return table.concat(out)
end

function M.json_unescape(s)
    return s
        :gsub('\\"',  '"')
        :gsub('\\n',  '\n')
        :gsub('\\r',  '\r')
        :gsub('\\t',  '\t')
        :gsub('\\\\', '\\')
end

-- ── sanitize UTF-8 string ───────────────────────────────
-- removes invalid bytes or surrogate pairs
function M.clean_utf8(s)
    if not s then return "" end
    local out = {}
    for p, c in utf8.codes(s) do
        table.insert(out, utf8.char(c))
    end
    return table.concat(out)
end

return M
