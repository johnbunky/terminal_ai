-- providers/openrouter.lua — OpenRouter API provider
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Reads:  OPENROUTER_API_KEY env var
--
-- opts:
--   opts.system   string
--   opts.model    string    (e.g. "openai/gpt-4o-mini", "anthropic/claude-3-haiku")
--   opts.history  table
--
-- openrouter.lua — OpenRouter API provider (OpenAI-compatible)
-- Exposes: M.call(prompt, opts) -> text, err, tokens

local utils     = require("core.utils")
local openai_like = require("core.openai_like")

local M = {}

local DEFAULT_MODEL = "openrouter/free"  -- free testing model
local API_URL = "https://openrouter.ai/api/v1/chat/completions"

-- ── build messages array ───────────────────────────────
local function build_messages(history, prompt, system)
    local turns = {}
    if system and system ~= "" then
        table.insert(turns,
            string.format('{"role":"system","content":"%s"}', utils.json_str(system))
        )
    end
    for _, m in ipairs(history or {}) do
        table.insert(turns,
            string.format('{"role":"%s","content":"%s"}',
                m.role, utils.json_str(m.content))
        )
    end
    table.insert(turns,
        string.format('{"role":"user","content":"%s"}', utils.json_str(prompt))
    )
    return "[" .. table.concat(turns, ",") .. "]"
end

-- ── build payload ──────────────────────────────────────
local function build_payload(model, messages, opts)
    return string.format(
        '{"model":"%s","messages":%s}',
        model, messages
    )
end

-- ── extract response ───────────────────────────────────
local function extract_response(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local text = s:match('"message"%s*:%s*{.-"content"%s*:%s*"(.-[^\\])"')
               or s:match('"message"%s*:%s*{.-"content"%s*:%s*"()"')
    return text and utils.json_unescape(text) or nil
end

-- ── extract error ──────────────────────────────────────
local function extract_error(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local msg = s:match('"error"%s*:%s*{.-"message"%s*:%s*"(.-[^\\])"')
    return msg and utils.json_unescape(msg) or nil
end

-- ── extract usage ──────────────────────────────────────
local function extract_usage(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local input  = tonumber(s:match('"prompt_tokens"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"completion_tokens"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── M.call ─────────────────────────────────────────────
function M.call(prompt, opts)
    local config = {
        api_key_env    = "OPENROUTER_API_KEY",
        model_env      = "OPENROUTER_MODEL",
        default_model  = DEFAULT_MODEL,
        url            = API_URL,
        build_messages = build_messages,
        build_payload  = build_payload,
        extract_response = extract_response,
        extract_error    = extract_error,
        extract_usage    = extract_usage,
    }

    return openai_like.call(config, prompt, opts)
end

return M
