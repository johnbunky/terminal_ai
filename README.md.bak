# **ai — universal AI CLI for the terminal**

A small command-line assistant that works anywhere Lua and curl are available.
It does one thing: connects your shell to any AI provider.
Nothing more. Nothing hidden.

It behaves like a regular UNIX tool.
You can pipe data in.
You can pipe data out.
You can script it.
You can read its files.
You stay in control.

---

## **Why this project exists**

Most AI tools want to move your work into their world.
The goal here is the opposite.

This project brings AI into *your* environment —
your shell, your editor, your habits, your own way of thinking.

The design follows a few simple ideas:

* A terminal is already an excellent workflow engine.
* AI should be a small tool you can combine with others.
* Nothing should be locked away behind an interface.
* Plain text is always better than proprietary formats.
* The user decides the provider, the model, and the cost.

A quiet tool that fits into the space you already use.

---

## **Features**

* Multiple providers: Groq, Gemini, Claude, OpenAI, OpenRouter
* Shared conversation history stored as plain text
* History can be shown, compacted, or cleared
* Pipes work naturally: `cat file | ai - "summarize"`
* Pipe macros let you define reusable workflows
* Provider and model switches on any command
* Token usage tracking
* Runs anywhere Lua runs
* One-command install

---

## **Requirements**

* Lua 5.4+
* curl
* jq (only for Claude)

---

## **Installation**

```sh
git clone https://github.com/johnbunky/terminal_ai.git
cd terminal_ai
lua install.lua
```

Reload your shell as instructed by the installer.

---

## **Usage**

Send a message:

```sh
ai "your message"
```

Combine it with stdin:

```sh
cat file.txt | ai - "summarize"
ai - < file.txt
```

Set a system prompt:

```sh
ai "message" --system "you are a pirate"
```

Temporary provider or model:

```sh
ai -p claude "explain"
ai -m llama-3.3-70b-versatile "draft code"
```

---

## **Session management**

```sh
ai --history    # show past messages
ai --compact    # compress history into one entry
ai --clear      # erase history and counters
ai --provider   # interactive provider switch
ai -h           # help
```

---

## **Pipe macros**

A pipe macro is a named template for workflows that involve `ai`.
Arguments use `$1`, `$2`, `$*`.
Use `$AI` inside templates. It expands to the full path of the script.

Create or edit pipes:

```sh
ai --pipe
```

Run one:

```sh
ai +name args...
```

---

## **Examples**

### Review a file

Template:

```
cat $1 | $AI - "review this code"
```

Usage:

```sh
ai +review main.lua
```

---

### Explain a range of lines

Template:

```
sed -n "$2p" $1 | $AI - "explain this code"
```

Usage:

```sh
ai +explain main.lua 11,16
```

---

### Create a commit message from the current diff

Template:

```
git diff | $AI - "write a commit message"
```

Usage:

```sh
ai +commit
```

---

### Apply an AI-generated patch

Template:

```
cat $1 | $AI - "$2" | patch -u $1
```

Usage:

```sh
ai +patch main.lua "improve error handling"
```

---

## **Providers**

| Provider   | Free | Env var                              | Default model               |
| ---------- | ---- | ------------------------------------ | --------------------------- |
| Groq       | yes  | `GROQ_API_KEY`                       | `llama-3.3-70b-versatile`   |
| Gemini     | yes  | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `gemini-2.5-flash`          |
| OpenRouter | yes  | `OPENROUTER_API_KEY`                 | `openrouter/free`           |
| Claude     | no   | `ANTHROPIC_API_KEY`                  | `claude-haiku-4-5-20251001` |
| OpenAI     | no   | `OPENAI_API_KEY`                     | `gpt-4o-mini`               |

---

## **Adding a provider**

Copy an existing provider, for example:

```
providers/groq.lua → providers/yourprovider.lua
```

Modify:

* API endpoint
* API key environment variable
* default model

Then add the provider name to the list in `ai.lua`.

Each provider exports:

```lua
M.call(prompt, opts) -> text, err, tokens
```

Where `opts` may contain:

```lua
opts.system
opts.history
opts.model
```

---

## **File layout**

```
terminal_ai/
  ai.lua
  install.lua
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

User data is stored in your home directory:

```
~/.airc        # current provider
~/.ai_history  # conversation history
~/.ai_usage    # token counters
~/.ai_pipes    # pipe definitions
```
