-- ai.lua — universal AI CLI entry point
-- Usage:
--   ai "hello"
--   ai "summarize this" -                  reads stdin too
--   cat file.txt | ai - "question"         pipe + question
--   ai - < file.txt                        redirect as prompt
--   ai "hello" --system "you are a pirate"
--   ai "hello" --provider gemini           one-off override
--   ai --clear                             clear conversation history
--   ai --history                           show conversation history
--   ai --pipe                              create/edit/delete a pipe macro
--   ai +name arg1 arg2                     run a pipe macro

-- ── platform ──────────────────────────────────────────────────────────────────

local IS_WIN    = package.config:sub(1,1) == "\\"
local SEP       = IS_WIN and "\\" or "/"
local HOME      = os.getenv(IS_WIN and "USERPROFILE" or "HOME") or "."
local AIRC_PATH  = HOME .. SEP .. ".airc"
local HIST_PATH  = HOME .. SEP .. ".ai_history"
local USAGE_PATH = HOME .. SEP .. ".ai_usage"
local PIPES_PATH = HOME .. SEP .. ".ai_pipes"

-- ── ANSI support detection ───────────────────────────────────────────────────

local function supports_ansi()
    local override = os.getenv("AI_COLOR")
    if override == "1" then return true  end
    if override == "0" then return false end
    if os.getenv("WT_SESSION")    then return true end
    if os.getenv("CLINK_VERSION") then return true end
    if os.getenv("ANSICON")       then return true end
    if os.getenv("ConEmuANSI") == "ON" then return true end
    local term = os.getenv("TERM")
    if term and term ~= "" and term ~= "dumb" then return true end
    return false
end

local GRAY  = supports_ansi() and "\27[90m" or ""
local RESET = supports_ansi() and "\27[0m"  or ""

local SCRIPT_DIR = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
-- $AI in pipe templates expands to this — works without clink aliases
local AI_CMD = 'lua "' .. SCRIPT_DIR .. SEP .. 'ai.lua"'

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

-- ── pipe macros ───────────────────────────────────────────────────────────────
-- ~/.ai_pipes format:  name<TAB>template  (one per line)
--
-- Placeholders:
--   $1 $2 $3 ...  positional args passed after +name
--   $*            all args joined by space
--
-- Examples in ~/.ai_pipes:
--   review    cat $1 | ai - "review this, be concise"
--   explain   sed -n "$2p" $1 | ai - "explain this code"
--   patch     cat $1 | ai - "$2" | patch -u $1
--   commit    git diff | ai - "write a commit message"
--
-- Create / edit:  ai --pipe  (same name overwrites)
-- Delete:         ai --pipe  (enter name, leave template blank)

local function load_pipes()
    local raw = read_file(PIPES_PATH)
    if not raw or raw:match("^%s*$") then return {}, {} end
    local pipes = {}
    local order = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        line = trim(line)
        if line ~= "" and not line:match("^%-%-") then
            local name, template = line:match("^(%S+)\t(.+)$")
            if name and template then
                if not pipes[name] then table.insert(order, name) end
                pipes[name] = template
            end
        end
    end
    return pipes, order
end

local function save_pipes(pipes, order)
    local lines = {}
    for _, name in ipairs(order) do
        if pipes[name] then
            table.insert(lines, name .. "\t" .. pipes[name])
        end
    end
    write_file(PIPES_PATH, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

local function expand_template(template, args)
    local result = template
    -- $AI expands to the full lua invocation (works without shell aliases)
    result = result:gsub("%$AI", AI_CMD)
    for idx, val in ipairs(args) do
        result = result:gsub("%$" .. idx, val)
    end
    result = result:gsub("%$%*", table.concat(args, " "))
    return result
end

local function run_pipe(name, args)
    local pipes = load_pipes()
    local template = pipes[name]
    if not template then
        io.stderr:write("Unknown pipe: +" .. name .. "\n")
        io.stderr:write("Run 'ai -h' to see available pipes.\n")
        os.exit(1)
    end
    local cmd = expand_template(template, args)
    io.stderr:write(GRAY .. "[+" .. name .. "] " .. cmd .. RESET .. "\n")
    local ok = os.execute(cmd)
    os.exit(ok and 0 or 1)
end

local function pipe_dialog()
    io.stdout:write("-- Pipe macro --------------------------------------------\n")
    io.stdout:write("Placeholders: $1 $2 $3 positional  $* all args  $AI this tool\n")
    io.stdout:write("Leave template blank to DELETE an existing pipe.\n\n")

    io.write("Name: ")
    io.flush()
    local name = trim(io.stdin:read("*l") or "")
    if name == "" then io.stderr:write("Aborted.\n"); os.exit(1) end
    if name:match("%s") then io.stderr:write("Name cannot contain spaces.\n"); os.exit(1) end

    local pipes, order = load_pipes()

    if pipes[name] then
        io.stdout:write("Current: " .. pipes[name] .. "\n")
    end

    io.write("Template (blank to delete): ")
    io.flush()
    local template = trim(io.stdin:read("*l") or "")

    -- delete
    if template == "" then
        if pipes[name] then
            pipes[name] = nil
            local new_order = {}
            for _, n in ipairs(order) do
                if n ~= name then table.insert(new_order, n) end
            end
            save_pipes(pipes, new_order)
            io.stdout:write("Deleted: +" .. name .. "\n")
        else
            io.stdout:write("Not found: +" .. name .. "\n")
        end
        os.exit(0)
    end

    -- optional test preview
    io.write("Test args (blank to skip): ")
    io.flush()
    local test_input = trim(io.stdin:read("*l") or "")
    if test_input ~= "" then
        local test_args = {}
        for a in test_input:gmatch("%S+") do table.insert(test_args, a) end
        local expanded = expand_template(template, test_args)
        io.stdout:write("Preview: " .. expanded .. "\n")
        io.write("Save? [y/n]: ")
        io.flush()
        if trim(io.stdin:read("*l") or "") ~= "y" then
            io.stderr:write("Aborted.\n"); os.exit(1)
        end
    end

    if not pipes[name] then table.insert(order, name) end
    pipes[name] = template
    save_pipes(pipes, order)
    io.stdout:write("Saved: +" .. name .. "\n")
    io.stdout:write("Usage: ai +" .. name .. " <args>\n")
    os.exit(0)
end

-- ── provider config ─────────────────────────────────────────────────────────
-- .airc format:
--   provider=groq
--   groq_model=llama-3.3-70b-versatile
--   openrouter_model=deepseek/deepseek-v3.2

local PROVIDERS = { "gemini", "claude", "openai", "groq", "openrouter" }

local function read_config()
    local cfg = {}
    local raw = read_file(AIRC_PATH)
    if not raw then return cfg end
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        line = trim(line)
        local k, v = line:match("^([%w_]+)=(.+)$")
        if k then cfg[k] = v end
    end
    return cfg
end

local function write_config(cfg)
    local lines = {}
    if cfg.provider then
        table.insert(lines, "provider=" .. cfg.provider)
    end
    local keys = {}
    for k in pairs(cfg) do
        if k ~= "provider" then table.insert(keys, k) end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.insert(lines, k .. "=" .. cfg[k])
    end
    write_file(AIRC_PATH, table.concat(lines, "\n") .. "\n")
end

local function read_provider()
    return read_config().provider or "groq"
end

local function write_provider(name)
    local cfg = read_config()
    cfg.provider = name
    write_config(cfg)
    io.stderr:write("Provider set to: " .. name .. "\n")
end

local function read_saved_model(provider)
    return read_config()[provider .. "_model"]
end

local function write_saved_model(provider, model)
    local cfg = read_config()
    if model == "" then
        cfg[provider .. "_model"] = nil
    else
        cfg[provider .. "_model"] = model
    end
    write_config(cfg)
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

local function clear_history()
    local f = io.open(HIST_PATH, "wb")
    if f then f:close() end
    reset_usage()
    io.stderr:write("History cleared.\n")
    os.exit(0)
end

local function compact_history(opts)
    opts = opts or {}
    local msgs = load_history()
    if #msgs == 0 then
        io.stderr:write("No history to compact.\n")
        os.exit(0)
    end
    local lines = { "Summarize this conversation concisely for future context." }
    table.insert(lines, "Keep: all decisions, key facts, names, open questions.")
    table.insert(lines, "Discard: pleasantries, repeated explanations.")
    table.insert(lines, "Output only the summary, no preamble.\n\nCONVERSATION:")
    for _, m in ipairs(msgs) do
        table.insert(lines, "[" .. m.role:upper() .. "]: " .. m.content:sub(1, 600))
    end
    local summary_prompt = table.concat(lines, "\n")
    local provider_name = opts.provider or read_provider()
    local provider      = load_provider(provider_name)
    io.stderr:write(GRAY .. "Compacting " .. #msgs .. " messages via " .. provider_name ..
        (opts.model and " | " .. opts.model or "") .. "..." .. RESET .. "\n")
    local summary, err = provider.call(summary_prompt, { model = opts.model })
    if not summary then
        io.stderr:write("Error during compaction: " .. (err or "unknown") .. "\n")
        os.exit(1)
    end
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

-- ── parse args ──────────────────────────────────────────────────────────────── ────────────────────────────────────────────────────────────────

local user_parts    = {}
local system_prompt = nil
local provider_flag = nil
local model_flag    = nil
local read_stdin    = false

local function show_help()
    local provider    = read_provider()
    local pipes, order = load_pipes()

    local pipes_lines = ""
    if #order > 0 then
        pipes_lines = "\nDefined pipes:\n"
        for _, name in ipairs(order) do
            pipes_lines = pipes_lines .. string.format("  +%-16s %s\n", name, pipes[name])
        end
    end

    io.stdout:write(
        "Usage:\n"
        .. "  ai \"message\"                    send a message\n"
        .. "  ai \"message\" -                  send a message + read stdin\n"
        .. "  cat file.txt | ai - \"question\"  pipe content with a question\n"
        .. "  ai - < file.txt                  use file as prompt\n"
        .. "  ai +name arg1 arg2               run a pipe macro\n"
        .. "\nOptions:\n"
        .. "  --system \"prompt\"               set a system prompt for this call\n"
        .. "  --provider <n> or -p <n>         use a specific provider this call\n"
        .. "  --provider or -p                 change active provider (interactive)\n"
        .. "  --model <n> or -m <n>            use a specific model this call\n"
        .. "  --model or -m                    set model for active provider (interactive)\n"
        .. "\nSession:\n"
        .. "  --history                        show conversation + token usage\n"
        .. "  --compact                        summarize history into one message\n"
        .. "  --clear                          clear history and reset token counter\n"
        .. "\nPipes:\n"
        .. "  --pipe                           create / edit / delete a pipe macro\n"
        .. pipes_lines
        .. "\nProviders:  " .. table.concat(PROVIDERS, "  ") .. "\n"
        .. "Active:     " .. provider .. "\n"
    )
    os.exit(0)
end


local function model_dialog()
    local provider_name = read_provider()
    local provider      = load_provider(provider_name)
    local models        = provider.MODELS

    if not models or #models == 0 then
        io.stderr:write("No model list defined for provider: " .. provider_name .. "\n")
        os.exit(1)
    end

    local current = read_saved_model(provider_name)
    io.stdout:write("-- Models for " .. provider_name .. " "
        .. string.rep("-", math.max(0, 38 - #provider_name)) .. "\n")
    for idx, m in ipairs(models) do
        local marker = ""
        if m == current then marker = " <-- saved"
        elseif idx == 1 and not current then marker = " (default)"
        elseif idx == 1 then marker = " (default)" end
        io.stdout:write("  " .. idx .. ") " .. m .. marker .. "\n")
    end
    io.stdout:write("Choose [1-" .. #models .. "] or blank to reset to default: ")
    io.flush()

    local input  = trim(io.stdin:read("*l") or "")
    local choice = tonumber(input)

    if input == "" then
        write_saved_model(provider_name, "")
        io.stdout:write("Reset " .. provider_name .. " to default model.\n")
    elseif choice and models[choice] then
        write_saved_model(provider_name, models[choice])
        io.stdout:write("Saved: " .. provider_name .. " -> " .. models[choice] .. "\n")
    else
        io.stderr:write("Invalid choice.\n"); os.exit(1)
    end
    os.exit(0)
end

local i = 1
while i <= #arg do
    if     arg[i] == "--clear"                                      then clear_history()
    elseif arg[i] == "--compact"                                    then compact_history({ provider = provider_flag, model = model_flag })
    elseif arg[i] == "--history"                                    then show_history()
    elseif arg[i] == "--pipe"                                       then pipe_dialog()
    elseif arg[i] == "-h" or arg[i] == "--help"                     then show_help()
    elseif arg[i] == "--system"  and arg[i+1]                       then system_prompt = arg[i+1]; i = i + 2
    elseif (arg[i] == "--provider" or arg[i] == "-p") and arg[i+1]  then provider_flag = arg[i+1]; i = i + 2
    elseif  arg[i] == "--provider" or arg[i] == "-p"                then switch_provider()
    elseif (arg[i] == "--model" or arg[i] == "-m") and arg[i+1] and arg[i+1]:sub(1,1) ~= "-" then model_flag = arg[i+1]; i = i + 2
    elseif  arg[i] == "--model" or arg[i] == "-m"                   then model_dialog()
    elseif arg[i] == "-"                                            then read_stdin = true; i = i + 1
    elseif arg[i]:sub(1,1) == "+"                                   then
        local pipe_name = arg[i]:sub(2)
        local pipe_args = {}
        for j = i+1, #arg do table.insert(pipe_args, arg[j]) end
        run_pipe(pipe_name, pipe_args)
    else
        table.insert(user_parts, arg[i]); i = i + 1
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

-- ── load history + usage ──────────────────────────────────────────────────────

local history = load_history()
local usage   = load_usage()

-- ── route to provider ─────────────────────────────────────────────────────────

local provider_name   = provider_flag or read_provider()
local provider        = load_provider(provider_name)
local effective_model = model_flag or read_saved_model(provider_name)

io.stderr:write(GRAY .. "[" .. provider_name
    .. (effective_model and " | " .. effective_model or "")
    .. " | " .. #history .. " msgs in history]" .. RESET .. "\n")

local response, err, tokens = provider.call(full_prompt, {
    system  = system_prompt,
    history = history,
    model   = effective_model,
})

if not response then
    io.stderr:write("Error: " .. (err or "unknown") .. "\n")
    os.exit(1)
end

-- ── token tracking ────────────────────────────────────────────────────────────

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
