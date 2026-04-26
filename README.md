# **ai — universal AI CLI for the terminal**

A small command-line assistant that works anywhere Lua and curl are available.  
It does one thing: connects your shell to any AI provider. Nothing more. Nothing hidden.

It behaves like a regular UNIX tool.  
You can pipe data in.  
You can pipe data out.  
You can script it.  
You can read its files.  
You stay in control.

---

## **Why this project exists**

Most AI tools want to move your work into their world. The goal here is the opposite.

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
* One‑command install

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

Temporary provider or model (model selection is per‑provider and persists):

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
ai --model      # interactive per‑provider model picker
ai -h           # help
```

---

## **Pipe macros**

A pipe macro is a named template for workflows that involve `ai`.  
Arguments use `$1`, `$2`, `$3` … positional, `$*` all args, and `$AI` (still supported) which expands to the full path of the script. You can also simply write `ai` in the template.

Create or edit pipes:

```sh
ai --pipe
```

Run one:

```sh
ai +name args...
```

### Note on `$AI`

`$AI` is a placeholder that expands to the absolute path of the `ai` script, useful when the script is not in `PATH`. For most cases you can write `ai` directly in your macro templates.

---

## **Examples**

### Review a file

Template:

```
cat $1 | ai - "review this code"
```

Usage:

```sh
ai +review main.lua
```

---

### Explain a range of lines

Template:

```
sed -n "$2p" $1 | ai - "explain this code"
```

Usage:

```sh
ai +explain main.lua 11,16
```

---

### Create a commit message from the current diff

Template:

```
git diff | ai - "write a commit message"
```

Usage:

```sh
ai +commit
```

---

### Apply an AI‑generated patch

Template:

```
cat $1 | ai - "$2" | patch -u $1
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

*Models are now stored per‑provider in `~/.airc` (e.g. `groq_model=…`). Use `ai --model` to select a model for the active provider.*

---

## **Model selection**

The `--model` option now works **per provider** and persists the chosen model in `~/.airc`.

* Set a specific model for the current provider (persists):
  ```sh
  ai --model llama-3.3-70b-versatile
  ```

* Interactive model picker (per‑provider):
  ```sh
  ai --model
  ```

  The command lists the models supported by the active provider, marks the current default, and lets you pick a new one or reset to the provider’s default.

---

## **Configuration file (`.airc`)**

The configuration file in your home directory stores the active provider and optionally a saved model for each provider.

Example `~/.airc` after selecting a provider and model:

```
provider=groq
groq_model=llama-3.3-70b-versatile
openrouter_model=deepseek/deepseek-v2
```

The file is updated automatically when you run `ai --provider` or `ai --model`.

---

## **Adding a provider**

Copy an existing provider, for example:

```
providers/groq.lua → providers/yourprovider.lua
```

Modify:

* API endpoint  
* API key environment variable  
* Default model (the first entry in the `M.MODELS` table)  

Then add the provider name to the list in `ai.lua`.

Each provider must export:

```lua
M.call(prompt, opts) -> text, err, tokens
```

where `opts` may contain:

```lua
opts.system   -- optional system prompt
opts.history  -- array of {role, content} for multi‑turn conversation
opts.model    -- optional model override
```

Make sure the new provider defines a table `M.MODELS` listing the models it supports; the first entry is used as the default.

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
~/.airc        # current provider and per‑provider model selections
~/.ai_history  # conversation history
~/.ai_usage    # token counters
~/.ai_pipes    # pipe definitions
```
