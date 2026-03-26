# ai — universal AI CLI in Lua

A lightweight command-line AI assistant that works everywhere Lua and curl are available:
Windows (CMD/clink), fish, bash, zsh, Termux, iSH.

## Features

- Multiple providers: Groq, Gemini, Claude, OpenAI, OpenRouter
- Conversation history across calls
- Pipe anything in: `cat file.txt | ai - "summarize"`
- Switch providers mid-session, shared history
- Token usage tracking
- Pipe macros: save and reuse complex pipe chains as short commands
- One-command install per device

## Requirements

- Lua 5.4+
- curl
- jq (for Claude provider only)

## Install

```bash
git clone https://github.com/johnbunky/terminal_ai.git
cd terminal_ai
lua install.lua
```

Then reload your shell config (the installer tells you exactly which command).

## Usage

```bash
ai "your message"
ai "question" -                   # include stdin too
cat file.txt | ai - "summarize"   # pipe content
ai - < file.txt                   # redirect as prompt

ai "message" --system "you are a pirate"
ai "message" --provider claude            # one-off provider override
ai "message" --model llama-3.3-70b-versatile  # one-off model override
ai "message" -p groq -m llama-3.3-70b-versatile
```

## Session management

```bash
ai --history    # show conversation + token usage
ai --compact    # summarize history into one message (saves tokens)
ai --clear      # wipe history and reset token counter
ai --provider   # change active provider (interactive menu)
ai -h           # show all commands
```

## Pipe macros

Save complex pipe chains as short reusable commands.
Use `$1 $2 $3` for positional args, `$*` for all args, `$AI` to call back into ai.

```bash
ai --pipe       # create / edit / delete a pipe (interactive)
ai -h           # lists all defined pipes
ai +name arg1   # run a pipe
```

### Example pipes

```bash
# review a file
# template: cat $1 | $AI - "review this code, be concise"
ai +review main.lua

# explain a line range
# template: sed -n "$2p" $1 | $AI - "explain this code"
ai +explain main.lua 11,16

# git commit message from current diff
# template: git diff | $AI - "write a commit message"
ai +commit

# apply AI suggestions as a patch
# template: cat $1 | $AI - "$2" | patch -u $1
ai +patch main.lua "fix error handling"
```

> **Note:** Use `$AI` instead of `ai` in templates — `ai` is a shell alias
> and won't work inside `os.execute()`. `$AI` expands to the full
> `lua "/path/to/ai.lua"` invocation automatically.

## Providers

| Provider   | Free | Key env var | Default model |
|------------|------|-------------|---------------|
| Groq       | ✅ yes (default) | `GROQ_API_KEY` | `llama-3.3-70b-versatile` |
| Gemini     | ✅ yes | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `gemini-2.5-flash` |
| OpenRouter | ✅ yes (free tier) | `OPENROUTER_API_KEY` | `openrouter/free` |
| Claude     | ❌ paid | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| OpenAI     | ❌ paid | `OPENAI_API_KEY` | `gpt-4o-mini` |

Free keys: [console.groq.com](https://console.groq.com) · [openrouter.ai](https://openrouter.ai) · [aistudio.google.com](https://aistudio.google.com)

## Adding a provider

1. Copy `providers/groq.lua` to `providers/yourprovider.lua`
2. Change the API endpoint, key env var, and default model
3. Add `"yourprovider"` to the `PROVIDERS` list in `ai.lua`

The provider must expose one function:

```lua
M.call(prompt, opts) -> text, err, tokens
-- opts.system   string
-- opts.history  table of {role, content}
-- opts.model    string (optional override)
```

## File layout

```
terminal_ai/
  ai.lua              entry point
  install.lua         one-time setup per device
  README.md
  providers/
    core/
      http.lua
      openai_like.lua
      utils.lua
    groq.lua
    gemini.lua
    claude.lua
    openai.lua
    openrouter.lua
```

Config and history live in your home directory (`~`), not in the repo:

- `~/.airc` — active provider name
- `~/.ai_history` — conversation history
- `~/.ai_usage` — session token counters
- `~/.ai_pipes` — saved pipe macros
