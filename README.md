# 泰.nvim

![tai.nvim in action](www/screenshot.png)

> A minimal, dependency-free Neovim plugin that brings AI coding agents directly
> into your editor. It uses a **subtask harness** (main → plan/code), per-agent
> working memory, session persistence, and many LLM providers.

<a href="https://dotfyle.com/plugins/blmayer/tai">
	<img src="https://dotfyle.com/plugins/blmayer/tai/shield?style=flat" />
</a>

## Features

- **Subtask harness** — a main orchestrator spawns plan/code subtasks with
  isolated history; only summaries return to the parent.
- **Working memory** — each agent has private `notes` and `todos`, injected into
  the system prompt every request (not stored in chat history).
- **Session persistence** — conversations are saved and restored between Neovim
  sessions (`.tai-session.json` in the project root).
- **Tool use** — read/write files, shell, edit, images, subtask/complete.
- **Rate limiting** — configurable `rpm` / `tpm`.
- **Streaming and non-streaming** for all providers.
- **Code folding** — tool output and whole subtasks fold in the chat buffer.
- **Provider-side tools** — pass-through for e.g. `web_search`.
- **Configurable shell safety** — allowlist of commands without confirmation.

## Agent harness

```
┌─────────────────────────────────────────────────────────────┐
│  MAIN (long-lived)                                          │
│  tools: read, shell, send_image, subtask, notes, todos      │
│  memory: notes + todos  ──► injected into system each turn  │
│                                                             │
│   user request                                              │
│        │                                                    │
│        ▼                                                    │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  SUBTASK profile=plan          {{{ fold             │   │
│   │  own history + notes/todos                          │   │
│   │  explore → sketch plan in notes → complete()        │   │
│   └───────────────────────┬─────────────────────────────┘   │
│                           │ summary + notes + todos         │
│                           ▼                                 │
│   merge into main memory, request auth if needed            │
│        │                                                    │
│        ▼                                                    │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  SUBTASK profile=code          {{{ fold             │   │
│   │  seeded with plan notes                             │   │
│   │  implement → verify → complete()                    │   │
│   └───────────────────────┬─────────────────────────────┘   │
│                           │ report + notes + todos          │
│                           ▼                                 │
│   verify lightly → answer user                              │
└─────────────────────────────────────────────────────────────┘
```

**Rules of the harness:**

1. Each frame (main or subtask) has its own history and notes/todos.
2. Notes/todos are **request-time only** — merged into the single system message
   when calling the API; never written into message history.
3. `subtask` opens a chat fold; `complete` closes it and returns
   `status`, `summary`, child notes, and child todos to the parent.
4. Max depth is 2 (main + one subtask). Plan and code run sequentially, not nested.

## Providers

| Provider | Environment Variable | Notes |
|---|---|---|
| Gemini | `GEMINI_API_KEY` | |
| Groq | `GROQ_API_KEY` | |
| Minimax | `MINIMAX_API_KEY` | |
| Mistral | `MISTRAL_API_KEY` | |
| Ollama | *(none)* | Local, `localhost:11434` |
| llama.cpp | *(none)* | Local, `localhost:8080` |
| OpenAI | `OPENAI_API_KEY` | Chat Completions API |
| OpenAI Responses | `OPENAI_API_KEY` | Responses API |
| OpenRouter | `OPENROUTER_API_KEY` | |
| StepFun | `STEPFUN_API_KEY` | |
| xAI | `XAI_API_KEY` | |
| Z.AI | `Z_AI_API_KEY` | |
| Zyphra | `ZYPHRA_API_KEY` | |
| Custom | *(via `options.url`)* | Any OpenAI-compatible endpoint |

## Installation

### Requirements

- Neovim 0.10+
- curl (for API calls)
- An API key for your chosen provider

### Plugin Managers

#### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  "blmayer/tai",
  opts = {},
  keys = {
    { "<leader>tt", "<cmd>Tai chat<cr>", desc = "Open Tai chat" },
    { "<leader>tc", "<cmd>Tai reload<cr>", desc = "Reload Tai config" },
    { "<leader>tr", "<cmd>Tai clear<cr>", desc = "Clear Tai history" },
    { "<leader>ts", "<cmd>Tai stop<cr>", desc = "Stop Tai" },
  },
}
```

#### [Packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use("blmayer/tai")
```

#### [vim-plug](https://junegunn.github.io/vim-plug/)

```vim
Plug "blmayer/tai"
```

#### Native / Manual Installation

```lua
local tai = require("tai")
tai.setup({})

vim.keymap.set("n", "<leader>tt", tai.chat, { noremap = true })
vim.keymap.set("n", "<leader>tc", tai.reload, { noremap = true })
vim.keymap.set("n", "<leader>tr", tai.clear_history, { noremap = true })
vim.keymap.set("n", "<leader>ts", tai.stop, { noremap = true })
vim.keymap.set("n", "<C-W><C-T>", tai.toggle_chat_window, { noremap = true })
```

## Project Configuration

tai reads configuration from a `.tai` JSON file in your project root:

| Key | Type | Default | Description |
|---|---|---|---|
| `provider` | string | — | Provider name (see table above) |
| `model` | string | — | Model identifier (e.g. `"gemini-2.0-flash"`) |
| `options` | object | `{}` | Provider-specific options |
| `stream` | boolean | `false` | Enable streaming responses |
| `use_tools` | boolean | `true` | Enable/disable agent tools |
| `think` | string | — | Reasoning effort for supporting models |
| `rpm` | number | `60` | Max requests per minute |
| `tpm` | number | — | Max tokens per minute |
| `provider_tools` | array | — | Provider-side tools (e.g. `["web_search"]`) |
| `system_prompt` | string | — | Override the default main system prompt |
| `custom_prompt` | string | — | Extra instructions appended to the main prompt |
| `allowed_commands` | object | *(defaults)* | Map of allowed shell commands |

Default allowed commands: `cat`, `grep`, `ag`, `rg`, `ls`, `head`, `tail`,
`wc`, `diff`, `sort`, `uniq`, `find`, `file`, `stat`, `date`, `echo`, `tree`,
`pwd`, `which`, `type`.

Example `.tai` file:

```json
{
	"provider": "groq",
	"model": "llama-3.1-70b-versatile",
	"stream": true,
	"rpm": 30,
	"options": {
		"temperature": 0.7,
		"max_tokens": 4096
	},
	"use_tools": true,
	"custom_prompt": "Prefer using rust over python for performance-critical code.",
	"allowed_commands": {
		"git": true,
		"npm": true,
		"make": true
	}
}
```

## Agent Tools

| Tool | Who | Description |
|---|---|---|
| `read` | main, plan, code | Read file contents (optional line range) |
| `shell` | main, plan, code | Run shell commands in the project root |
| `send_image` | main, plan, code | Send images for visual analysis |
| `edit` | code | Search-and-replace edit (`multi` flag supported) |
| `write` | code | Create new files |
| `subtask` | main | Spawn plan or code child (own history + memory) |
| `complete` | plan, code | Finish subtask; return summary + notes + todos |
| `todos` | all | Add/update todos (list is auto-injected) |
| `notes` | all | Write/append notes (content is auto-injected) |

## Running Tests

```sh
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/test_edit.lua" -c "qa!"
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/test_persist.lua" -c "qa!"
```

## Screenshots

- ![tai.nvim in action](www/screenshot.png)
- ![side panel](www/2025-08-05-174307_1372x1415_scrot.png)
- ![side panel with folding](www/folding.png)

## License

This project is licensed under the MIT License.
