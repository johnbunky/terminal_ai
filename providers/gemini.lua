-- providers/gemini.lua — Google Gemini API provider
-- Exposes: M.call(prompt, opts) -> text, err
--
-- opts:
--   opts.system   string    system instruction (optional)
--   opts.model    string    override model (default: gemini-2.5-flash)
--   opts.history  table     array of {role, content} for multi-turn conversation

local utils = require("core.utils")
local http  = require("core.http")

local M = {}

local DEFAULT_MODEL = "gemini-2.5-flash"

-- ── build contents ──────────────────────────────────────
local function build_contents(history, prompt)
    local turns = {}

    for _, m in ipairs(history or {}) do
        local role = (m.role == "assistant") and "model" or "user"
        table.insert(turns,
            string.format('{"role":"%s","parts":[{"text":"%s"}]}',
                role, utils.json_str(m.content))
        )
    end

    table.insert(turns,
        string.format('{"role":"user","parts":[{"text":"%s"}]}',
            utils.json_str(prompt))
    )

    return "[" .. table.concat(turns, ",") .. "]"
end

-- ── extract response ────────────────────────────────────
local function extract_response(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")

    local text = s:match(
        '"candidates"%s*:%s*%[%s*{.-"parts"%s*:%s*%[%s*{.-"text"%s*:%s*"(.-[^\\])"'
    )

    return text and utils.json_unescape(text) or nil
end

-- ── extract error ───────────────────────────────────────
local function extract_error(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local msg = s:match('"error"%s*:%s*{.-"message"%s*:%s*"(.-[^\\])"')
    return msg and utils.json_unescape(msg) or nil
end

-- ── extract usage ───────────────────────────────────────
local function extract_usage(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local input  = tonumber(s:match('"promptTokenCount"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"candidatesTokenCount"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── M.call ──────────────────────────────────────────────
function M.call(prompt, opts)
    opts = opts or {}

    local api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    if not api_key or api_key == "" then
        return nil, "GOOGLE_API_KEY (or GEMINI_API_KEY) is not set"
    end

    local model = opts.model or os.getenv("GEMINI_MODEL") or DEFAULT_MODEL

    local contents = build_contents(opts.history, prompt)

    local sys_block = ""
    if opts.system and opts.system ~= "" then
        sys_block = string.format(
            ',"systemInstruction":{"role":"system","parts":[{"text":"%s"}]}',
            utils.json_str(opts.system)
        )
    end

    local payload = string.format(
        '{"model":"%s","contents":%s%s}',
        model, contents, sys_block
    )

    local url = string.format(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent",
        model
    )

    local raw, err = http.post(url, payload, {
        headers = {
            ["x-goog-api-key"] = api_key
        }
    })

    if not raw then return nil, err end

    local api_err = extract_error(raw)
    if api_err then return nil, "API error: " .. api_err end

    local text = extract_response(raw)
    if not text or text == "" then
        return nil, "could not parse response.\nRaw: " .. raw:sub(1,300)
    end

    local tokens = extract_usage(raw)
    return text, nil, tokens
end

return M
