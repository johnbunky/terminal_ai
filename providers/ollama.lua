-- providers/ollama.lua — local Ollama provider (OpenAI-ish, no API key)
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Requires a running local server: `ollama serve` (usually auto-started)
-- Pull a model first:              `ollama pull llama3.2`
-- Host override:                   OLLAMA_HOST=http://localhost:11434
-- Model override:                  OLLAMA_MODEL=llama3.2  (or .airc: ollama_model=...)

local M = {}

M.MODELS = {
    "llama3.2:3b",        -- default
    "qwen2.5-coder:3b",
    "deepseek-r1:7b",
    "deepseek-r1:1.5b",
}

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"
local TMPDIR = IS_WIN
    and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
    or  (os.getenv("TMPDIR") or "/tmp")

local DEFAULT_MODEL = M.MODELS[1]
local DEFAULT_HOST  = "http://localhost:11434"

local function tmpfile(suffix)
    math.randomseed(os.time())
    local stamp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    return TMPDIR .. SEP .. "ai_ollama_" .. stamp .. (suffix or ".tmp")
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

local function extract_response(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local text = s:match('"message"%s*:%s*{.-"content"%s*:%s*"(.-[^\\])"')
               or s:match('"message"%s*:%s*{.-"content"%s*:%s*"()"')
    if not text then return nil end
    return json_unescape(text)
end

-- Ollama errors are a flat top-level string, e.g. {"error":"model 'x' not found"}
-- (not nested under an "error":{"message":...} object like the hosted APIs).
local function extract_error(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local msg = s:match('^%s*{%s*"error"%s*:%s*"(.-[^\\])"')
    return msg and json_unescape(msg) or nil
end

-- Ollama reports counts as prompt_eval_count / eval_count, not *_tokens.
local function extract_usage(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local input  = tonumber(s:match('"prompt_eval_count"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"eval_count"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

local function build_messages(history, prompt, system)
    local turns = {}
    if system and system ~= "" then
        table.insert(turns,
            string.format('{"role":"system","content":"%s"}', json_str(system))
        )
    end
    for _, m in ipairs(history or {}) do
        table.insert(turns,
            string.format('{"role":"%s","content":"%s"}', m.role, json_str(m.content))
        )
    end
    table.insert(turns,
        string.format('{"role":"user","content":"%s"}', json_str(prompt))
    )
    return "[" .. table.concat(turns, ",") .. "]"
end

function M.call(prompt, opts)
    opts = opts or {}

    local host  = os.getenv("OLLAMA_HOST") or DEFAULT_HOST
    -- strip a trailing slash so host..."/api/chat" doesn't double up
    host = host:gsub("/+$", "")

    local model    = opts.model or os.getenv("OLLAMA_MODEL") or DEFAULT_MODEL
    local messages = build_messages(opts.history, prompt, opts.system)
    -- stream:false is required — otherwise Ollama returns newline-delimited
    -- JSON chunks instead of one object, which the regex parser can't read.
    local payload  = string.format(
        '{"model":"%s","messages":%s,"stream":false}', model, messages
    )

    local tmp_pay = tmpfile("_pay.json")
    write_file(tmp_pay, payload)

    local cmd = string.format(
        'curl -s --connect-timeout 3 %s/api/chat' ..
        ' -H "Content-Type: application/json"' ..
        ' --data-binary @"%s"',
        host, tmp_pay
    )

    local pipe = io.popen(cmd)
    if not pipe then os.remove(tmp_pay); return nil, "failed to run curl" end
    local raw = pipe:read("*a") or ""
    pipe:close()
    os.remove(tmp_pay)

    if raw == "" then
        return nil, "no response from Ollama at " .. host ..
            " — is it running? (try: ollama serve)"
    end
    local api_err = extract_error(raw)
    if api_err then
        local hint = api_err:match("not found")
            and "\nHint: pull it first — ollama pull " .. model
            or ""
        return nil, "Ollama error: " .. api_err .. hint
    end
    local text = extract_response(raw)
    if not text or text == "" then
        return nil, "could not parse response.\nRaw: " .. raw:sub(1, 300)
    end
    return text, nil, extract_usage(raw)
end

return M
