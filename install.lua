-- install.lua — sets up the `ai` alias for the current platform
-- Run once on each device: lua install.lua
--
-- Supported:
--   Windows  + clink   → appends to %LOCALAPPDATA%\clink\aliases.lua
--   macOS    + zsh     → appends to ~/.zshrc
--   macOS    + bash    → appends to ~/.bash_profile
--   Linux    + bash    → appends to ~/.bashrc
--   Linux    + zsh     → appends to ~/.zshrc
--   Termux   (bash)    → appends to ~/.bashrc
--   iSH      (ash)     → appends to ~/.profile

-- ── helpers ───────────────────────────────────────────────────────────────────

local IS_WIN = package.config:sub(1,1) == "\\"
local SEP    = IS_WIN and "\\" or "/"

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local c = f:read("*a"); f:close()
    return c
end

local function append_file(path, content)
    local f = assert(io.open(path, "ab"))
    f:write(content); f:close()
end

local function ask(question)
    io.write(question .. " ")
    io.flush()
    return (io.stdin:read("*l") or ""):match("^%s*(.-)%s*$"):lower()
end

-- ── resolve this script's directory (= where ai.lua lives) ───────────────────

local SCRIPT_DIR = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
-- Resolve to absolute path if relative
if not SCRIPT_DIR:match("^[A-Za-z]:\\") and not SCRIPT_DIR:match("^/") then
    local pwd
    if IS_WIN then
        local p = io.popen("cd"); pwd = p:read("*l"); p:close()
    else
        local p = io.popen("pwd"); pwd = p:read("*l"); p:close()
    end
    SCRIPT_DIR = (pwd or ".") .. SEP .. SCRIPT_DIR
end

local AI_LUA = SCRIPT_DIR .. SEP .. "ai.lua"

-- ── platform detection ────────────────────────────────────────────────────────

local function detect_platform()
    if IS_WIN then return "windows" end

    -- Termux sets PREFIX pointing to /data/data/com.termux
    if (os.getenv("PREFIX") or ""):match("termux") then return "termux" end

    -- iSH: kernel uname contains "iSH"
    local uname = io.popen("uname -a 2>/dev/null")
    local uname_str = uname and uname:read("*l") or ""
    if uname then uname:close() end
    if uname_str:match("[Ii][Ss][Hh]") then return "ish" end

    -- macOS
    if uname_str:match("Darwin") then return "macos" end

    -- Linux fallback
    return "linux"
end

local function detect_shell()
    local shell = os.getenv("SHELL") or ""
    if shell:match("zsh")  then return "zsh"  end
    if shell:match("fish") then return "fish" end
    if shell:match("bash") then return "bash" end
    return "sh"
end

-- ── platform-specific install ─────────────────────────────────────────────────

local platform = detect_platform()
local shell    = detect_shell()

print("Platform : " .. platform)
print("Shell    : " .. shell)
print("ai.lua   : " .. AI_LUA)
print("")

-- ── windows + clink ───────────────────────────────────────────────────────────

if platform == "windows" then
    local clink_dir = (os.getenv("LOCALAPPDATA") or "") .. "\\clink"
    local aliases_file = clink_dir .. "\\aliases.lua"

    -- Check if already installed
    local existing = read_file(aliases_file)
    if existing:match("ai%.lua") then
        print("Already installed in: " .. aliases_file)
        print("Line found: ai alias pointing to ai.lua")
        os.exit(0)
    end

    local alias_line = string.format(
        '\nos.setalias("ai", \'lua "%s" $*\')\n',
        AI_LUA
    )

    print("Will append to: " .. aliases_file)
    print("Line: " .. alias_line)
    local confirm = ask("Proceed? [y/n]")
    if confirm ~= "y" then print("Aborted."); os.exit(0) end

    append_file(aliases_file, alias_line)
    print("Done. Restart clink or run: clink reload")
    os.exit(0)
end

-- ── fish ──────────────────────────────────────────────────────────────────────

if shell == "fish" then
    local config_dir = (os.getenv("HOME") or "") .. "/.config/fish"
    local config_file = config_dir .. "/config.fish"

    local existing = read_file(config_file)
    if existing:match("ai%.lua") then
        print("Already installed in: " .. config_file)
        os.exit(0)
    end

    local alias_line = string.format(
        '\nfunction ai\n    lua "%s" $argv\nend\n',
        AI_LUA
    )

    print("Will append to: " .. config_file)
    print(alias_line)
    local confirm = ask("Proceed? [y/n]")
    if confirm ~= "y" then print("Aborted."); os.exit(0) end

    append_file(config_file, alias_line)
    print("Done. Run: source ~/.config/fish/config.fish")
    os.exit(0)
end

-- ── posix shells: bash / zsh / sh / ash (iSH, Termux) ────────────────────────

local rc_candidates = {
    ish     = { "~/.profile",      "~/.ashrc"  },
    termux  = { "~/.bashrc",       "~/.profile" },
    macos   = { "~/.zshrc",        "~/.bash_profile", "~/.bashrc" },
    linux   = { "~/.bashrc",       "~/.zshrc"  },
}

local HOME = os.getenv("HOME") or "."

local function expand(path)
    return path:gsub("^~", HOME)
end

-- Pick first candidate that exists, or default to first
local candidates = rc_candidates[platform] or { "~/.bashrc" }
local rc_file = expand(candidates[1])
for _, c in ipairs(candidates) do
    if exists(expand(c)) then
        rc_file = expand(c); break
    end
end

local existing = read_file(rc_file)
if existing:match("ai%.lua") then
    print("Already installed in: " .. rc_file)
    os.exit(0)
end

local alias_line = string.format(
    '\nalias ai=\'lua "%s"\'\n',
    AI_LUA
)

print("Will append to: " .. rc_file)
print("Line:" .. alias_line)
local confirm = ask("Proceed? [y/n]")
if confirm ~= "y" then print("Aborted."); os.exit(0) end

append_file(rc_file, alias_line)
print("Done. Run: source " .. rc_file)
