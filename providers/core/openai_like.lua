-- openai_like.lua — generic OpenAI-compatible API call

local utils = require("core.utils")
local http  = require("core.http")

local M = {}

-- config = {
--   api_key_env, model_env, default_model,
--   url,
--   build_messages(history,prompt,system),
--   build_payload(model,messages,opts),
--   extract_response(raw),
--   extract_error(raw),
--   extract_usage(raw)
-- }
function M.call(config, prompt, opts)
    opts = opts or {}

    local api_key = os.getenv(config.api_key_env)
    if not api_key or api_key == "" then
        return nil, config.api_key_env .. " is not set"
    end

    local model = opts.model or os.getenv(config.model_env) or config.default_model
    local messages = config.build_messages(opts.history, prompt, opts.system)

    local payload = config.build_payload(model, messages, opts)
    local raw, err = http.post(config.url, payload, api_key)
    if not raw then return nil, err end

    local api_err = config.extract_error(raw)
    if api_err then return nil, "API error: " .. api_err end

    local text = config.extract_response(raw)
    if not text or text == "" then
        return nil, "could not parse response.\nRaw: " .. raw:sub(1,300)
    end

    local tokens = config.extract_usage and config.extract_usage(raw) or nil
    return text, nil, tokens
end

return M
