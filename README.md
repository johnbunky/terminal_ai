# ai — universal AI CLI in Lua

A lightweight command-line AI assistant that works everywhere Lua and curl are available:
Windows (CMD/clink), fish, bash, zsh, Termux, iSH.

## Features

- Multiple providers: Groq, Gemini, Claude, OpenAI
- Conversation history across calls
- Pipe anything in: `cat file.txt | ai - "summarize"`
- Switch providers mid-session, shared history
- Token usage tracking
- One-command install per device

## Requirements

- Lua 5.4+
- curl
- jq (for Claude provider only)

## Install

```bash
# clone
git clone https://github.com/johnbunky/terminal_ai.git
cd terminal_ai

# run installer (detects your platform and shell)
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
ai "message" --provider claude    # one-off provider override
ai "message" --model llama3-8b-8192  # one-off model override
ai "message" --provider groq --model llama3-8b-8192
```

## Session management

```bash
ai --history    # show conversation + token usage
ai --compact    # summarize history into one message (saves tokens)
ai --clear      # wipe history and reset token counter
ai --provider   # change active provider (interactive menu)
ai -h           # show all commands
```

## Providers

| Provider   | Free | Key env var | Default model |
|------------|------|-------------|---------------|
| Groq       | ✅ yes (default) | `GROQ_API_KEY` | `llama-3.3-70b-versatile` |
| Gemini     | ✅ yes | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `gemini-2.5-flash` |
| Openrouter | ✅ yes | `OPENROUTER_API_KEY` | `openrouter/free` |
| Claude     | ❌ paid | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| OpenAI     | ❌ paid | `OPENAI_API_KEY` | `gpt-4o-mini` |

Get a free Groq key at [console.groq.com](https://console.groq.com) — no credit card.

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
ai/
  ai.lua              entry point
  install.lua         one-time setup per device
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
