-- ai.lua — universal AI CLI entry point
-- Usage:
--   ai "hello"
--   ai "summarize this" -                  reads stdin too
--   cat file.txt | ai - "question"         pipe + question
--   ai - < file.txt                        redirect as prompt
--   ai "hello" --system "you are a pirate"
--   ai "hello" --provider gemini           one-off override
--   ai --switch                            change active provider
--   ai --clear                             clear conversation history
--   ai --history                           show conversation history

-- ── platform ──────────────────────────────────────────────────────────────────

local IS_WIN    = package.config:sub(1,1) == "\\"
local SEP       = IS_WIN and "\\" or "/"
local HOME      = os.getenv(IS_WIN and "USERPROFILE" or "HOME") or "."
local AIRC_PATH  = HOME .. SEP .. ".airc"
local HIST_PATH  = HOME .. SEP .. ".ai_history"
local USAGE_PATH = HOME .. SEP .. ".ai_usage"

-- ── ANSI support detection ───────────────────────────────────────────────────
-- Override: set AI_COLOR=1 (force on) or AI_COLOR=0 (force off) in your env.
-- Auto-detect checks common terminal signals across Windows/Unix.

local function supports_ansi()
    local override = os.getenv("AI_COLOR")
    if override == "1" then return true  end
    if override == "0" then return false end
    if os.getenv("WT_SESSION")    then return true end  -- Windows Terminal
    if os.getenv("CLINK_VERSION") then return true end  -- clink
    if os.getenv("ANSICON")       then return true end  -- ANSICON
    if os.getenv("ConEmuANSI") == "ON" then return true end  -- ConEmu
    local term = os.getenv("TERM")
    if term and term ~= "" and term ~= "dumb" then return true end
    return false
end

local GRAY  = supports_ansi() and "\27[90m" or ""
local RESET = supports_ansi() and "\27[0m"  or ""

local SCRIPT_DIR = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."

-- ── helpers ───────────────────────────────────────────────────────────────────

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return c
end

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content); f:close()
end

-- ── usage tracking ───────────────────────────────────────────────────────────

local function load_usage()
    local raw = read_file(USAGE_PATH)
    if not raw then return { session_in = 0, session_out = 0 } end
    local si = tonumber(raw:match("in:(%d+)"))  or 0
    local so = tonumber(raw:match("out:(%d+)")) or 0
    return { session_in = si, session_out = so }
end

local function save_usage(u)
    write_file(USAGE_PATH, "in:" .. u.session_in .. "\nout:" .. u.session_out .. "\n")
end

local function reset_usage()
    save_usage({ session_in = 0, session_out = 0 })
end

-- ── history ───────────────────────────────────────────────────────────────────
-- Simple delimiter format — no JSON, no escaping issues.
-- Each message block:
--   <<<MSG>>>
--   <<<ROLE:user>>>
--   content here
--   <<<MSG>>>
--   <<<ROLE:assistant>>>
--   content here

local DELIM = "<<<MSG>>>"

local function load_history()
    local raw = read_file(HIST_PATH)
    if not raw or raw:match("^%s*$") then return {} end

    local msgs  = {}
    local role  = nil
    local lines = {}

    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line == DELIM then
            if role and #lines > 0 then
                local content = table.concat(lines, "\n"):gsub("\n$", "")
                table.insert(msgs, { role = role, content = content })
            end
            role  = nil
            lines = {}
        elseif line:sub(1, 8) == "<<<ROLE:" then
            role  = line:match("<<<ROLE:(.-)>>>") or "user"
            lines = {}
        else
            table.insert(lines, line)
        end
    end

    return msgs
end

local function save_history(msgs)
    local parts = {}
    for _, m in ipairs(msgs) do
        table.insert(parts, DELIM)
        table.insert(parts, "<<<ROLE:" .. m.role .. ">>>")
        table.insert(parts, m.content)
    end
    table.insert(parts, DELIM)
    write_file(HIST_PATH, table.concat(parts, "\n"))
end

-- ── provider config ──────────────────────────────────────────────────────────

local PROVIDERS = { "gemini", "claude", "openai", "groq" }

local function read_provider()
    local raw = read_file(AIRC_PATH)
    if raw then
        local p = trim(raw)
        if p ~= "" then return p end
    end
    return "groq"
end

local function write_provider(name)
    write_file(AIRC_PATH, name .. "\n")
    io.stderr:write("Provider set to: " .. name .. "\n")
end

local function load_provider(name)
    local path = SCRIPT_DIR .. SEP .. "providers" .. SEP .. name .. ".lua"
    if not io.open(path, "r") then
        io.stderr:write("Error: provider not found: " .. path .. "\n")
        os.exit(1)
    end
    package.path = SCRIPT_DIR .. SEP .. "providers" .. SEP .. "?.lua;" .. package.path
    local ok, mod = pcall(require, name)
    if not ok then
        io.stderr:write("Error loading provider '" .. name .. "':\n" .. tostring(mod) .. "\n")
        os.exit(1)
    end
    return mod
end

local function clear_history()
    local f = io.open(HIST_PATH, "wb")
    if f then f:close() end
    reset_usage()
    io.stderr:write("History cleared.\n")
    os.exit(0)
end

local function compact_history()
    local msgs = load_history()
    if #msgs == 0 then
        io.stderr:write("No history to compact.\n")
        os.exit(0)
    end

    -- build a summarization prompt from current history
    local lines = { "Summarize this conversation concisely for future context." }
    table.insert(lines, "Keep: all decisions, key facts, names, open questions.")
    table.insert(lines, "Discard: pleasantries, repeated explanations.")
    table.insert(lines, "Output only the summary, no preamble.\n\nCONVERSATION:")
    for _, m in ipairs(msgs) do
        table.insert(lines, "[" .. m.role:upper() .. "]: " .. m.content:sub(1, 600))
    end
    local summary_prompt = table.concat(lines, "\n")

    -- load provider and call it
    local provider_name = read_provider()
    local provider      = load_provider(provider_name)

    io.stderr:write(GRAY .. "Compacting " .. #msgs .. " messages via " .. provider_name .. "..." .. RESET .. "\n")

    local summary, err = provider.call(summary_prompt, {})
    if not summary then
        io.stderr:write("Error during compaction: " .. (err or "unknown") .. "\n")
        os.exit(1)
    end

    -- replace entire history with one summary message
    local compacted = { { role = "user", content = "[CONVERSATION SUMMARY]\n" .. summary } }
    save_history(compacted)
    reset_usage()

    io.stderr:write(GRAY .. "Compacted to 1 message. Tokens reset." .. RESET .. "\n")
    os.exit(0)
end

local function show_history()
    local msgs  = load_history()
    local usage = load_usage()
    if #msgs == 0 then
        io.stderr:write("No history.\n")
        os.exit(0)
    end
    for _, m in ipairs(msgs) do
        local prefix = (m.role == "user") and (GRAY .. ">" .. RESET .. " ") or (GRAY .. "<" .. RESET .. " ")
        io.stderr:write(prefix .. m.content .. "\n")
    end
    io.stderr:write(string.format(
        "%s(%d messages | session tokens: %d in / %d out)%s\n",
        GRAY, #msgs, usage.session_in, usage.session_out, RESET
    ))
    os.exit(0)
end

local function switch_provider()
    io.stderr:write("Available providers:\n")
    for idx, name in ipairs(PROVIDERS) do
        io.stderr:write("  " .. idx .. ") " .. name .. "\n")
    end
    io.stderr:write("Choose [1-" .. #PROVIDERS .. "]: ")
    local input = io.stdin:read("*l")
    local choice = tonumber(trim(input or ""))
    if choice and PROVIDERS[choice] then
        write_provider(PROVIDERS[choice])
    else
        io.stderr:write("Invalid choice.\n")
        os.exit(1)
    end
    os.exit(0)
end

-- ── parse args ────────────────────────────────────────────────────────────────

local user_parts    = {}
local system_prompt = nil
local provider_flag = nil
local model_flag    = nil
local read_stdin    = false

local function show_help()
    local provider = read_provider()
    io.stdout:write(
        "Usage:\n" ..
        "  ai \"message\"                    send a message\n" ..
        "  ai \"message\" -                  send a message + read stdin\n" ..
        "  cat file.txt | ai - \"question\"  pipe content with a question\n" ..
        "  ai - < file.txt                  use file as prompt\n" ..
        "\nOptions:\n" ..
        "  --system \"prompt\"               set a system prompt for this call\n" ..
        "  --provider <n>               use a specific provider this call\n" ..
        "  --model <n>                  use a specific model this call\n" ..
        "\nSession:\n" ..
        "  --switch                        change active provider (interactive)\n" ..
        "  --history                       show conversation + token usage\n" ..
        "  --compact                       summarize history into one message\n" ..
        "  --clear                         clear history and reset token counter\n" ..
        "\nProviders:  " .. table.concat(PROVIDERS, "  ") .. "\n" ..
        "Active:     " .. provider .. "\n"
    )
    os.exit(0)
end

local i = 1
while i <= #arg do
    if     arg[i] == "--switch"                 then switch_provider()
    elseif arg[i] == "--clear"                  then clear_history()
    elseif arg[i] == "--compact"                then compact_history()
    elseif arg[i] == "--history"                then show_history()
    elseif arg[i] == "-h" or arg[i] == "--help" then show_help()
    elseif arg[i] == "--system"   and arg[i+1] then system_prompt = arg[i+1]; i = i + 2
    elseif arg[i] == "--provider" and arg[i+1] then provider_flag = arg[i+1]; i = i + 2
    elseif arg[i] == "--model"    and arg[i+1] then model_flag    = arg[i+1]; i = i + 2
    elseif arg[i] == "-"                        then read_stdin = true;        i = i + 1
    else   table.insert(user_parts, arg[i]);                                   i = i + 1
    end
end

local user_message = (#user_parts > 0) and table.concat(user_parts, " ") or nil

if not user_message and not read_stdin then
    io.stderr:write("No message. Try: ai -h\n")
    os.exit(1)
end

-- ── read stdin ────────────────────────────────────────────────────────────────

local stdin_content = nil

if read_stdin then
    local lines = {}
    for line in io.stdin:lines() do
        table.insert(lines, line)
    end
    local raw = table.concat(lines, "\n")
    if trim(raw) ~= "" then stdin_content = raw end
end

-- ── build prompt ──────────────────────────────────────────────────────────────

local parts = {}
if stdin_content then
    table.insert(parts, "=== INPUT ===\n" .. stdin_content .. "\n=== END INPUT ===")
end
if user_message then
    table.insert(parts, user_message)
end
local full_prompt = table.concat(parts, "\n\n")

-- ── load history + usage ─────────────────────────────────────────────────────

local history = load_history()
local usage   = load_usage()

-- ── route to provider ─────────────────────────────────────────────────────────

local provider_name = provider_flag or read_provider()
local provider      = load_provider(provider_name)

io.stderr:write(GRAY .. "[" .. provider_name .. (model_flag and " | " .. model_flag or "") .. " | " .. #history .. " msgs in history]" .. RESET .. "\n")

local response, err, tokens = provider.call(full_prompt, {
    system  = system_prompt,
    history = history,
    model   = model_flag,
})

if not response then
    io.stderr:write("Error: " .. (err or "unknown") .. "\n")
    os.exit(1)
end

-- ── show token usage ──────────────────────────────────────────────────────────
-- Accumulated silently; visible in --history report only.

if tokens then
    usage.session_in  = usage.session_in  + (tokens.input  or 0)
    usage.session_out = usage.session_out + (tokens.output or 0)
    save_usage(usage)
end

-- ── save updated history ──────────────────────────────────────────────────────

table.insert(history, { role = "user",      content = full_prompt })
table.insert(history, { role = "assistant", content = response    })
save_history(history)

print(response)
