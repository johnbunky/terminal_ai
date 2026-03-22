-- providers/groq.lua — Groq API provider (OpenAI-compatible)
-- Exposes: M.call(prompt, opts) -> text, err, tokens
--
-- Reads:  GROQ_API_KEY env var
-- Get a free key at: https://console.groq.com
--
-- opts:
--   opts.system   string    system prompt (optional)
--   opts.model    string    override model (default: llama-3.3-70b-versatile)
--   opts.history  table     array of {role, content} for multi-turn conversation
--
-- Free tier limits (as of 2025):
--   llama-3.3-70b-versatile  : 1,000 req/day, 6,000 tokens/min
--   llama3-8b-8192           : 14,400 req/day, 30,000 tokens/min
--   gemma2-9b-it             : 14,400 req/day, 15,000 tokens/min

local openai_like = require("core.openai_like")
local utils       = require("core.utils")

local M = {}

local DEFAULT_MODEL = "llama-3.3-70b-versatile"
local API_URL       = "https://api.groq.com/openai/v1/chat/completions"

-- ── shared OpenAI-compatible helpers ────────────────────

local function build_messages(history, prompt, system)
    local turns = {}

    if system and system ~= "" then
        table.insert(turns,
            string.format('{"role":"system","content":"%s"}',
                utils.json_str(utils.clean_utf8(system)))
        )
    end

    for _, m in ipairs(history or {}) do
        table.insert(turns,
            string.format('{"role":"%s","content":"%s"}',
                m.role,
                utils.json_str(utils.clean_utf8(m.content)))
        )
    end

    table.insert(turns,
        string.format('{"role":"user","content":"%s"}',
            utils.json_str(utils.clean_utf8(prompt)))
    )

    return "[" .. table.concat(turns, ",") .. "]"
end

local function build_payload(model, messages)
    return string.format(
        '{"model":"%s","messages":%s}',
        model, messages
    )
end

local function extract_response(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local text = s:match('"message"%s*:%s*{.-"content"%s*:%s*"(.-[^\\])"')
               or s:match('"message"%s*:%s*{.-"content"%s*:%s*"()"')
    return text and utils.json_unescape(text) or nil
end

local function extract_error(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local msg = s:match('"error"%s*:%s*{.-"message"%s*:%s*"(.-[^\\])"')
    return msg and utils.json_unescape(msg) or nil
end

local function extract_usage(raw)
    local s = raw:gsub("\r",""):gsub("\n"," ")
    local input  = tonumber(s:match('"prompt_tokens"%s*:%s*(%d+)'))
    local output = tonumber(s:match('"completion_tokens"%s*:%s*(%d+)'))
    if not input then return nil end
    return { input = input, output = output or 0 }
end

-- ── M.call ──────────────────────────────────────────────

function M.call(prompt, opts)
    local config = {
        api_key_env   = "GROQ_API_KEY",
        model_env     = "GROQ_MODEL",
        default_model = DEFAULT_MODEL,
        url           = API_URL,

        build_messages  = build_messages,
        build_payload   = build_payload,
        extract_response = extract_response,
        extract_error    = extract_error,
        extract_usage    = extract_usage,
    }

    return openai_like.call(config, prompt, opts)
end

return M
