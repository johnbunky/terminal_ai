-- providers/gemini.lua — Google Gemini API provider
-- Exposes: M.call(prompt, opts) -> text, err
--
-- opts:
--   opts.system   string    system instruction (optional)
--   opts.model    string    override model (default: gemini-2.5-flash)
--   opts.history  table     array of {role, content} for multi-turn conversation

local M = {}

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"
local TMPDIR = IS_WIN
    and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
    or  (os.getenv("TMPDIR") or "/tmp")

local DEFAULT_MODEL = "gemini-2.5-flash"

-- ── helpers ───────────────────────────────────────────────────────────────────

local function tmpfile(suffix)
    math.randomseed(os.time())
    local stamp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    return TMPDIR .. SEP .. "ai_gemini_" .. stamp .. (suffix or ".tmp")
end

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content); f:close()
end

local function json_str(s)
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

local function json_unescape(s)
    return s
        :gsub('\\"',  '"')
        :gsub('\\n',  '\n')
        :gsub('\\r',  '\r')
        :gsub('\\t',  '\t')
        :gsub('\\\\', '\\')
end

local function extract_usage(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local prompt_tokens     = tonumber(s:match('"promptTokenCount"%s*:%s*(%d+)'))
    local candidates_tokens = tonumber(s:match('"candidatesTokenCount"%s*:%s*(%d+)'))
    if not prompt_tokens then return nil end
    return { input = prompt_tokens, output = candidates_tokens or 0 }
end

local function extract_response(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local text = s:match(
        '"candidates"%s*:%s*%[%s*{.-"content"%s*:%s*{.-"parts"%s*:%s*%[%s*{.-"text"%s*:%s*"(.-[^\\])"'
    ) or s:match(
        '"candidates"%s*:%s*%[%s*{.-"content"%s*:%s*{.-"parts"%s*:%s*%[%s*{.-"text"%s*:%s*"()"'
    )
    if not text then return nil end
    return json_unescape(text)
end

local function extract_error(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local msg = s:match('"error"%s*:%s*{.-"message"%s*:%s*"(.-[^\\])"')
    return msg and json_unescape(msg) or nil
end

-- ── build contents array (history + new prompt) ───────────────────────────────
-- Gemini roles must be "user" or "model" (not "assistant")

local function build_contents(history, prompt)
    local turns = {}
    for _, m in ipairs(history or {}) do
        local role = (m.role == "assistant") and "model" or "user"
        table.insert(turns,
            string.format('{"role":"%s","parts":[{"text":"%s"}]}',
                role, json_str(m.content))
        )
    end
    table.insert(turns,
        string.format('{"role":"user","parts":[{"text":"%s"}]}', json_str(prompt))
    )
    return "[" .. table.concat(turns, ",") .. "]"
end

-- ── M.call ────────────────────────────────────────────────────────────────────

function M.call(prompt, opts)
    opts = opts or {}

    local api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    if not api_key or api_key == "" then
        return nil, "GOOGLE_API_KEY (or GEMINI_API_KEY) is not set"
    end

    local model    = opts.model or os.getenv("GEMINI_MODEL") or DEFAULT_MODEL
    local contents = build_contents(opts.history, prompt)

    local sys_block = ""
    if opts.system and opts.system ~= "" then
        sys_block = string.format(
            ',"systemInstruction":{"role":"system","parts":[{"text":"%s"}]}',
            json_str(opts.system)
        )
    end

    local payload = string.format(
        '{"model":"%s","contents":%s%s}',
        model, contents, sys_block
    )

    local tmp_pay = tmpfile("_pay.json")
    write_file(tmp_pay, payload)

    local url = string.format(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent",
        model
    )

    local cmd = string.format(
        'curl -s "%s" -H "Content-Type: application/json" -H "x-goog-api-key: %s" -X POST --data-binary @"%s"',
        url, api_key, tmp_pay
    )

    local pipe = io.popen(cmd)
    if not pipe then
        os.remove(tmp_pay)
        return nil, "failed to run curl"
    end
    local raw = pipe:read("*a") or ""
    pipe:close()
    os.remove(tmp_pay)

    if raw == "" then return nil, "empty response from API" end

    local api_err = extract_error(raw)
    if api_err then return nil, "API error: " .. api_err end

    local text = extract_response(raw)
    if not text or text == "" then
        return nil, "could not parse response.\nRaw: " .. raw:sub(1, 300)
    end

    local tokens = extract_usage(raw)
    return text, nil, tokens
end

return M
