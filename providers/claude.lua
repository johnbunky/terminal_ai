-- providers/claude.lua — Anthropic Claude API provider
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Reads:  ANTHROPIC_API_KEY env var
--
-- opts:
--   opts.system   string    system prompt (optional)
--   opts.model    string    override model (default: claude-haiku-4-5-20251001)
--   opts.history  table     array of {role, content} for multi-turn conversation

local utils = require("core.utils")
local http  = require("core.http")

local M = {}

local DEFAULT_MODEL = "claude-haiku-4-5-20251001"
local API_URL       = "https://api.anthropic.com/v1/messages"

-- ── build messages ──────────────────────────────────────
local function build_messages(history, prompt)
    local turns = {}

    for _, m in ipairs(history or {}) do
        table.insert(turns,
            string.format('{"role":"%s","content":"%s"}',
                m.role, utils.json_str(m.content))
        )
    end

    table.insert(turns,
        string.format('{"role":"user","content":"%s"}',
            utils.json_str(prompt))
    )

    return "[" .. table.concat(turns, ",") .. "]"
end

-- ── extract response ────────────────────────────────────
local function extract_response(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")

    local text = s:match('"type"%s*:%s*"text"%s*,%s*"text"%s*:%s*"(.-[^\\])"')
               or s:match('"text"%s*:%s*"(.-[^\\])"')

    return text and utils.json_unescape(text) or nil
end

-- ── extract error ───────────────────────────────────────
local function extract_error(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local msg = s:match('"type"%s*:%s*"error".-"message"%s*:%s*"(.-[^\\])"')
    return msg and utils.json_unescape(msg) or nil
end

-- ── extract usage ───────────────────────────────────────
local function extract_usage(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local input  = tonumber(s:match('"input_tokens"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"output_tokens"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── M.call ──────────────────────────────────────────────
function M.call(prompt, opts)
    opts = opts or {}

    local api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key or api_key == "" then
        return nil, "ANTHROPIC_API_KEY is not set"
    end

    local model = opts.model or os.getenv("CLAUDE_MODEL") or DEFAULT_MODEL

    local messages = build_messages(opts.history, prompt)

    local sys_block = ""
    if opts.system and opts.system ~= "" then
        sys_block = string.format(
            ',"system":"%s"',
            utils.json_str(opts.system)
        )
    end

    local max_tok = opts.max_tokens or 2048

    local payload = string.format(
        '{"model":"%s","max_tokens":%d%s,"messages":%s}',
        model, max_tok, sys_block, messages
    )

    local raw, err = http.post(API_URL, payload, {
        headers = {
            ["x-api-key"] = api_key,
            ["anthropic-version"] = "2023-06-01"
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
