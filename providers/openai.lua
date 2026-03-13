-- providers/openai.lua — OpenAI API provider
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Reads:  OPENAI_API_KEY env var
--
-- opts:
--   opts.system   string    system prompt (optional)
--   opts.model    string    override model (default: gpt-4o-mini)
--   opts.history  table     array of {role, content} for multi-turn conversation

local M = {}

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"
local TMPDIR = IS_WIN
    and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
    or  (os.getenv("TMPDIR") or "/tmp")

-- gpt-4o-mini is cheap and fast — change via --model or OPENAI_MODEL env
local DEFAULT_MODEL = "gpt-4o-mini"

-- ── helpers ───────────────────────────────────────────────────────────────────

local function tmpfile(suffix)
    math.randomseed(os.time())
    local stamp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    return TMPDIR .. SEP .. "ai_openai_" .. stamp .. (suffix or ".tmp")
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

-- ── response parsing ──────────────────────────────────────────────────────────

local function extract_response(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local text = s:match('"message"%s*:%s*{.-"content"%s*:%s*"(.-[^\\])"')
               or s:match('"message"%s*:%s*{.-"content"%s*:%s*"()"')
    if not text then return nil end
    return json_unescape(text)
end

local function extract_error(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local msg = s:match('"error"%s*:%s*{.-"message"%s*:%s*"(.-[^\\])"')
    return msg and json_unescape(msg) or nil
end

local function extract_usage(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local input  = tonumber(s:match('"prompt_tokens"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"completion_tokens"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── build messages array ──────────────────────────────────────────────────────
-- OpenAI: system goes as first message with role "system"

local function build_messages(history, prompt, system)
    local turns = {}

    if system and system ~= "" then
        table.insert(turns,
            string.format('{"role":"system","content":"%s"}', json_str(system))
        )
    end

    for _, m in ipairs(history or {}) do
        table.insert(turns,
            string.format('{"role":"%s","content":"%s"}',
                m.role, json_str(m.content))
        )
    end

    table.insert(turns,
        string.format('{"role":"user","content":"%s"}', json_str(prompt))
    )

    return "[" .. table.concat(turns, ",") .. "]"
end

-- ── M.call ────────────────────────────────────────────────────────────────────

function M.call(prompt, opts)
    opts = opts or {}

    local api_key = os.getenv("OPENAI_API_KEY")
    if not api_key or api_key == "" then
        return nil, "OPENAI_API_KEY is not set"
    end

    local model    = opts.model or os.getenv("OPENAI_MODEL") or DEFAULT_MODEL
    local messages = build_messages(opts.history, prompt, opts.system)

    local payload = string.format(
        '{"model":"%s","messages":%s}',
        model, messages
    )

    local tmp_pay = tmpfile("_pay.json")
    write_file(tmp_pay, payload)

    local cmd = string.format(
        'curl -s https://api.openai.com/v1/chat/completions' ..
        ' -H "Content-Type: application/json"'              ..
        ' -H "Authorization: Bearer %s"'                    ..
        ' --data-binary @"%s"',
        api_key, tmp_pay
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
