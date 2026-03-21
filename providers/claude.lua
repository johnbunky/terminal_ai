-- providers/claude.lua — Anthropic Claude API provider
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Reads:  ANTHROPIC_API_KEY env var
--
-- opts:
--   opts.system   string    system prompt (optional)
--   opts.model    string    override model (default: claude-haiku-4-5-20251001)
--   opts.history  table     array of {role, content} for multi-turn conversation

local M = {}

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"
local TMPDIR = IS_WIN
    and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
    or  (os.getenv("TMPDIR") or "/tmp")

-- Haiku is the cheapest Claude model — change via --model or CLAUDE_MODEL env
local DEFAULT_MODEL = "claude-haiku-4-5-20251001"

-- ── helpers ───────────────────────────────────────────────────────────────────

local function tmpfile(suffix)
    math.randomseed(os.time())
    local stamp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    return TMPDIR .. SEP .. "ai_claude_" .. stamp .. (suffix or ".tmp")
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
    -- Claude: content[0].type == "text", content[0].text == "..."
    local text = s:match('"type"%s*:%s*"text"%s*,%s*"text"%s*:%s*"(.-[^\\])"')
               or s:match('"text"%s*:%s*"(.-[^\\])"')
    if not text then return nil end
    return json_unescape(text)
end

local function extract_error(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local msg = s:match('"type"%s*:%s*"error".-"message"%s*:%s*"(.-[^\\])"')
    return msg and json_unescape(msg) or nil
end

local function extract_usage(raw)
    local s = raw:gsub("\r", ""):gsub("\n", " ")
    local input  = tonumber(s:match('"input_tokens"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"output_tokens"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── build messages array (history + new prompt) ───────────────────────────────

local function build_messages(history, prompt)
    local turns = {}
    for _, m in ipairs(history or {}) do
        -- Claude uses "user" / "assistant" (same as our history format)
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

    local api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key or api_key == "" then
        return nil, "ANTHROPIC_API_KEY is not set"
    end

    local model    = opts.model or os.getenv("CLAUDE_MODEL") or DEFAULT_MODEL
    local messages = build_messages(opts.history, prompt)

    local sys_block = ""
    if opts.system and opts.system ~= "" then
        sys_block = string.format(',"system":"%s"', json_str(opts.system))
    end

    local max_tok = opts.max_tokens or 2048
    local payload = string.format(
        '{"model":"%s","max_tokens":%d%s,"messages":%s}',
        model, max_tok, sys_block, messages
    )

    local tmp_pay = tmpfile("_pay.json")
    write_file(tmp_pay, payload)

    local cmd = string.format(
        'curl -s https://api.anthropic.com/v1/messages'  ..
        ' -H "Content-Type: application/json"'           ..
        ' -H "anthropic-version: 2023-06-01"'            ..
        ' -H "x-api-key: %s"'                            ..
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
