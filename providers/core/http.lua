local utils = require("core.utils")

local M = {}

function M.post(url, payload, opts)
    -- backward compatibility
    local api_key = nil
    local headers_extra = {}

    if type(opts) == "string" then
        api_key = opts
    elseif type(opts) == "table" then
        api_key = opts.api_key
        headers_extra = opts.headers or {}
    end

    local tmp_pay = utils.tmpfile("_pay.json")
    utils.write_file(tmp_pay, payload)

    local headers = {
        ' -H "Content-Type: application/json"',
    }

    -- extra headers (Gemini, OpenRouter, etc.)
    for k, v in pairs(headers_extra) do
        headers[#headers+1] = string.format(' -H "%s: %s"', k, v)
    end

    -- default Authorization header
    if api_key and not headers_extra["Authorization"] and not headers_extra["x-goog-api-key"] then
        headers[#headers+1] = string.format(
            ' -H "Authorization: Bearer %s"', api_key
        )
    end

    local cmd = string.format(
        'curl -s "%s"%s --data-binary @"%s"',
        url, table.concat(headers, ""), tmp_pay
    )

    local pipe = io.popen(cmd)
    if not pipe then
        os.remove(tmp_pay)
        return nil, "failed to run curl"
    end

    local raw = pipe:read("*a") or ""
    pipe:close()
    os.remove(tmp_pay)

    if raw == "" then
        return nil, "empty response from API"
    end

    return raw
end

return M
