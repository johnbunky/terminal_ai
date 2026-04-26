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
    write_file(USAGE_PATH, "in:" .. u.session_in .. "\
out:" .. u.session_out .. "\
")
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

    for line in (raw .. "\
"):gmatch("([^\
]*)\
") do
        if line == DELIM then
            if role and #lines > 0 then
                local content = table.concat(lines, "\
"):gsub("\
$", "")
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
    write_file(HIST_PATH, table.concat(parts, "\
"))
end

-- ── pipe macros ───────────────────────────────────────────────────────────────
-- ~/.ai_pipes format:  name<TAB>template  (one per line)
--
-- Placeholders:
--   $1 $2 $3 ...  positional args passed after +name
--   $*            all args joined by space
--
-- Examples in ~/.ai_pipes:
--   review    cat $1 | $AI - "review this, be concise"
--   explain   sed -n "$2p" $1 | $AI - "explain this code"
--   patch     cat $1 | $AI - "$2" | patch -u $1
--   commit    git diff | $AI - "write a commit message"
--
-- Create / edit:  ai --pipe  (same name overwrites)
-- Delete:         ai --pipe  (enter name, leave template blank)

local function load_pipes()
    local raw = read_file(PIPES_PATH)
    if not raw or raw:match("^%s*$") then return {}, {} end
    local pipes = {}
    local order = {}
    for line in (raw .. "\
"):gmatch("([^\
]*)\
") do
        line = trim(line)
        if line ~= "" and not line:match("^%-%-") then
            local name, template = line:match("^(%S+)	(.+)$")
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
            table.insert(lines, name .. "	" .. pipes[name])
        end
    end
    write_file(PIPES_PATH, table.concat(lines, "\
") .. (#lines > 0 and "\
" or ""))
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
        io.stderr:write("Unknown pipe: +" .. name .. "\
")
        io.stderr:write("Run 'ai -h' to see available pipes.\
")
        os.exit(1)
    end
    local cmd = expand_template(template, args)
    io.stderr:write(GRAY .. "[+" .. name .. "] " .. cmd .. RESET .. "\
")
    local ok = os.execute(cmd)
    os.exit(ok and 0 or 1)
end

local function pipe_dialog()
    io.stdout:write("-- Pipe macro --------------------------------------------\
")
    io.stdout:write("Placeholders: $1 $2 $3 positional  $* all args  $AI this tool\
")
    io.stdout:write("Leave template blank to DELETE an existing pipe.\
\
")

    io.write("Name: ")
    io.flush()
    local name = trim(io.stdin:read("*l") or "")
    if name == "" then io.stderr:write("Aborted.\
"); os.exit(1) end
    if name:match("%s") then io.stderr:write("Name cannot contain spaces.\
"); os.exit(1) end

    local pipes, order = load_pipes()

    if pipes[name] then
        io.stdout:write("Current: " .. pipes[name] .. "\
")
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
            io.stdout:write("Deleted: +" .. name .. "\
")
        else
            io.stdout:write("Not found: +" .. name .. "\
")
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
        io.stdout:write("Preview: " .. expanded .. "\
")
        io.write("Save? [y/n]: ")
        io.flush()
        if trim(io.stdin:read("*l") or "") ~= "y" then
            io.stderr:write("Aborted.\
"); os.exit(1)
        end
    end

    if not pipes[name] then table.insert(order, name) end
    pipes[name] = template
    save_pipes(pipes, order)
    io.stdout:write("Saved: +" .. name .. "\
")
    io.stdout:write("Usage: ai +" .. name .. " <args>\
")
    os.exit(0)
end

-- ── provider config ───────────────────────────────────────────────────────────

local PROVIDERS = { "gemini", "claude", "openai", "groq", "openrouter" }

-- .airc supports two line formats:
--   provider:<name>   — active provider
--   model:<name>      — default model (optional)
-- A plain line with no colon is treated as the provider name (backward compat).

local function read_config()
    local raw = read_file(AIRC_PATH)
    local cfg = {}
    if raw then
        for line in (raw .. "\
"):gmatch("([^\
]*)\
") do
            line = trim(line)
            if line ~= "" then
                local key, val = line:match("^(%w+)%s*:%s*(.+)$")
                if key then
                    cfg[key] = val
                else
                    -- legacy: bare provider name
                    cfg.provider = line
                end
            end
        end
    end
    return cfg
end

local function write_config(cfg)
    local lines = {}
    if cfg.provider and cfg.provider ~= "" then
        table.insert(lines, "provider:" .. cfg.provider)
    end
    if cfg.model and cfg.model ~= "" then
        table.insert(lines, "model:" .. cfg.model)
    end
    write_file(AIRC_PATH, table.concat(lines, "\
") .. (#lines > 0 and "\
" or ""))
end

local function read_provider()
    local cfg = read_config()
    return cfg.provider or "groq"
end

local function write_provider(name)
    local cfg = read_config()
    cfg.provider = name
    write_config(cfg)
    io.stderr:write("Provider set to: " .. name .. "\
")
end

local function read_model()
    local cfg = read_config()
    return cfg.model  -- may be nil
end

local function write_model(name)
    local cfg = read_config()
    cfg.model = name
    write_config(cfg)
    io.stderr:write("Default model set to: " .. name .. "\
")
end

local function select_model()
    local current = read_model()
    if current then
        io.stderr:write("Current default model: " .. current .. "\
")
    end
    io.stderr:write("Enter new default model name (empty to cancel): ")
    io.flush()
    local input = trim(io.stdin:read("*l") or "")
    if input == "" then
        io.stderr:write("Aborted.\
")
        os.exit(1)
    end
    write_model(input)
    os.exit(0)
end

local function load_provider(name)
    local path = SCRIPT_DIR .. SEP .. "providers" .. SEP .. name .. ".lua"
    if not io.open(path, "r") then
        io.stderr:write("Error: provider not found: " .. path .. "\
")
        os.exit(1)
    end
    package.path = SCRIPT_DIR .. SEP .. "providers" .. SEP .. "?.lua;" .. package.path
    local ok, mod = pcall(require, name)
    if not ok then
        io.stderr:write("Error loading provider '" .. name .. "':\
" .. tostring(mod) .. "\
")
        os.exit(1)
    end
    return mod
end

local function clear_history()
    local f = io.open(HIST_PATH, "wb")
    if f then f:close() end
    reset_usage()
    io.stderr:write("History cleared.\
")
    os.exit(0)
end

local function compact_history(opts)
    opts = opts or {}
    local msgs = load_history()
    if #msgs == 0 then
        io.stderr:write("No history to compact.\
")
        os.exit(0)
    end

    local lines = { "Summarize this conversation concisely for future context." }
    table.insert(lines, "Keep: all decisions, key facts, names, open questions.")
    table.insert(lines, "Discard: pleasantries, repeated explanations.")
    table.insert(lines, "Output only the summary, no preamble.\
\
CONVERSATION:")
    for _, m in ipairs(msgs) do
        table.insert(lines, "[" .. m.role:upper() .. "]: " .. m.content:sub(1, 600))
    end
    local summary_prompt = table.concat(lines, "\
")

    local provider_name = opts.provider or read_provider()
    local provider      = load_provider(provider_name)

    local compact_model = opts.model or read_model()

    io.stderr:write(GRAY .. "Compacting " .. #msgs .. " messages via " .. provider_name ..
        (compact_model and " | " .. compact_model or "") .. "..." .. RESET .. "\
")

    local summary, err = provider.call(summary_prompt, { model = compact_model })
    if not summary then
        io.stderr:write("Error during compaction: " .. (err or "unknown") .. "\
")
        os.exit(1)
    end

    local compacted = { { role = "user", content = "[CONVERSATION SUMMARY]\
" .. summary } }
    save_history(compacted)

    io.stderr:write(GRAY .. "Compacted to 1 message." .. RESET .. "\
")
    os.exit(0)
end

local function show_history()
    local msgs  = load_history()
    local usage = load_usage()
    if #msgs == 0 then
        io.stderr:write("No history.\
")
        os.exit(0)
    end
    for _, m in ipairs(msgs) do
        local prefix = (m.role == "user") and (GRAY .. ">" .. RESET .. " ") or (GRAY .. "<" .. RESET .. " ")
        io.stderr:write(prefix .. m.content .. "\
")
    end
    io.stderr:write(string.format(
        "%s(%d messages | session tokens: %d in / %d out)%s\
",
        GRAY, #msgs, usage.session_in, usage.session_out, RESET
    ))
    os.exit(0)
end

local function switch_provider()
    io.stderr:write("Available providers:\
")
    for idx, name in ipairs(PROVIDERS) do
        io.stderr:write("  " .. idx .. ") " .. name .. "\
")
    end
    io.stderr:write("Choose [1-" .. #PROVIDERS .. "]: ")
    local input = io.stdin:read("*l")
    local choice = tonumber(trim(input or ""))
    if choice and PROVIDERS[choice] then
        write_provider(PROVIDERS[choice])
    else
        io.stderr:write("Invalid choice.\
")
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
    local provider  = read_provider()
    local model     = read_model() or "(none)"
    local pipes, order = load_pipes()

    local pipes_lines = ""
    if #order > 0 then
        pipes_lines = "\
Defined pipes:\
"
        for _, name in ipairs(order) do
            pipes_lines = pipes_lines .. string.format("  +%-16s %s\
", name, pipes[name])
        end
    end

    io.stdout:write(
        "Usage:\
"
        .. "  ai \"message\"                    send a message\
"
        .. "  ai \"message\" -                  send a message + read stdin\
"
        .. "  cat file.txt | ai - \"question\"  pipe content with a question\
"
        .. "  ai - < file.txt                  use file as prompt\
"
        .. "  ai +name arg1 arg2               run a pipe macro\
"
        .. "\
Options:\
"
        .. "  --system \"prompt\"               set a system prompt for this call\
"
        .. "  --provider <n> or -p <n>         use a specific provider this call\
"
        .. "  --provider or -p                 change active provider (interactive)\
"
        .. "  --model <n> or -m <n>            set default model (persists) and use this call\
"
        .. "  --model or -m                    interactively set default model\
"
        .. "\
Session:\
"
        .. "  --history                        show conversation + token usage\
"
        .. "  --compact                        summarize history into one message\
"
        .. "  --clear                          clear history and reset token counter\
"
        .. "\
Pipes:\
"
        .. "  --pipe                           create / edit / delete a pipe macro\
"
        .. pipes_lines
        .. "\
Providers:  " .. table.concat(PROVIDERS, "  ") .. "\
"
        .. "Active:     " .. provider .. " | Model: " .. model .. "\
"
    )
    os.exit(0)
end

local i = 1
while i <= #arg do
    if     arg[i] == "--clear"                                      then clear_history()
    elseif arg[i] == "--compact" then compact_history({ provider = provider_flag, model = model_flag })
    elseif arg[i] == "--history"                                    then show_history()
    elseif arg[i] == "--pipe"                                       then pipe_dialog()
    elseif arg[i] == "-h" or arg[i] == "--help"                     then show_help()
    elseif arg[i] == "--system"  and arg[i+1]                       then system_prompt = arg[i+1]; i = i + 2
    elseif (arg[i] == "--provider" or arg[i] == "-p") and arg[i+1]  then provider_flag = arg[i+1]; i = i + 2
    elseif  arg[i] == "--provider" or arg[i] == "-p"                then switch_provider()
    elseif (arg[i] == "--model"    or arg[i] == "-m") and arg[i+1]  then
        model_flag = arg[i+1]
        write_model(model_flag)   -- persist as new default
        i = i + 2
    elseif arg[i] == "--model" or arg[i] == "-m"                    then select_model()
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
    io.stderr:write("No message. Try: ai -h\
")
    os.exit(1)
end

-- ── read stdin ────────────────────────────────────────────────────────────────

local stdin_content = nil

if read_stdin then
    local lines = {}
    for line in io.stdin:lines() do
        table.insert(lines, line)
    end
    local raw = table.concat(lines, "\
")
    if trim(raw) ~= "" then stdin_content = raw end
end

-- ── build prompt ──────────────────────────────────────────────────────────────

local parts = {}
if stdin_content then
    table.insert(parts, "=== INPUT ===\
" .. stdin_content .. "\
=== END INPUT ===")
end
if user_message then
    table.insert(parts, user_message)
end
local full_prompt = table.concat(parts, "\
\
")

-- ── load history + usage ──────────────────────────────────────────────────────

local history = load_history()
local usage   = load_usage()

-- ── route to provider ─────────────────────────────────────────────────────────

local provider_name = provider_flag or read_provider()
local provider      = load_provider(provider_name)

-- model_flag is set if --model <name> was passed this invocation;
-- fall back to the persisted default from .airc.
local effective_model = model_flag or read_model()

io.stderr:write(GRAY .. "[" .. provider_name
    .. (effective_model and " | " .. effective_model or "")
    .. " | " .. #history .. " msgs in history]" .. RESET .. "\
")

local response, err, tokens = provider.call(full_prompt, {
    system  = system_prompt,
    history = history,
    model   = effective_model,
})

if not response then
    io.stderr:write("Error: " .. (err or "unknown") .. "\
")
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
