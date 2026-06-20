# 泰.nvim

![tai.nvim in action](www/screenshot.png)

> A minimal, dependency-free Neovim plugin that brings AI coding agents directly
> into your editor. It features a **planner/coder** dual-agent architecture,
> session persistence, in-memory task tracking, and support for many LLM
> providers.

<a href="https://dotfyle.com/plugins/blmayer/tai">
	<img src="https://dotfyle.com/plugins/blmayer/tai/shield?style=flat" />
</a>

## Features

- **Dual-agent architecture** — a planner agent coordinates work and a coder
  agent implements changes. Each has independent history and can delegate to the
  other.
- **Session persistence** — conversations are automatically saved and restored
  between Neovim sessions (stored as `.tai-session.json` in your project root).
- **In-memory task tracking** — agents can use `todos` and `notes` tools to
  stay organized during long multi-step tasks.
- **Tool use** — agents can read/write files, run shell commands, edit code,
  and send images for analysis.
- **Rate limiting** — configurable requests-per-minute (`rpm`) and
  tokens-per-minute (`tpm`) limits to stay within API quotas.
- **Streaming and non-streaming** — supports both modes for all providers.
- **Code folding** — tool output and thinking blocks are folded in the chat
  buffer for readability.
- **Provider-side tools** — pass-through support for provider tools like
  `web_search` or `web_browser`.
- **Configurable shell safety** — allowlist of shell commands the agent can run
  without confirmation.

## Providers

tai supports the following providers out of the box:

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
| Custom | *(via `options.url`)* | Any OpenAI-compatible endpoint |

Set the corresponding environment variable for your chosen provider.

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
    { "<leader>ta", "<cmd>Tai agent<cr>", desc = "Switch agent" },
    { "<leader>tr", "<cmd>Tai clear<cr>", desc = "Clear Tai history" },
    { "<leader>ts", "<cmd>Tai stop<cr>", desc = "Stop Tai" },
  },
}
```

#### [Packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use("blmayer/tai")
```

#### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug "blmayer/tai"
```

#### Native / Manual Installation

Clone or place `lua/tai/` into your Neovim config directory and add to `init.lua`:

```lua
local tai = require("tai")
tai.setup({})

-- Recommended keybindings
vim.keymap.set("n", "<leader>tt", tai.chat, { noremap = true })
vim.keymap.set("n", "<leader>tc", tai.reload, { noremap = true })
vim.keymap.set("n", "<leader>ta", tai.switch_agent, { noremap = true })
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
| `options` | object | `{}` | Provider-specific options (`temperature`, `max_tokens`, etc.) |
| `stream` | boolean | `false` | Enable streaming responses |
| `use_tools` | boolean | `true` | Enable/disable agent tools |
| `think` | string | — | Reasoning effort level for supporting models |
| `rpm` | number | `60` | Max requests per minute |
| `tpm` | number | — | Max tokens per minute |
| `provider_tools` | array | — | Provider-side tools (e.g. `["web_search"]`) |
| `system_prompt` | string | — | Override the default planner system prompt |
| `custom_prompt` | string | — | Extra instructions appended to the system prompt |
| `allowed_commands` | object | *(defaults)* | Map of allowed shell commands (`{"git": true, ...}`) |

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

The agents have access to these tools:

| Tool | Available to | Description |
|---|---|---|
| `read` | planner, coder | Read file contents (with optional line range) |
| `shell` | planner, coder | Run shell commands in the project root |
| `edit` | coder | Edit files with search-and-replace (supports `multi` flag) |
| `write` | coder | Create new files |
| `send_image` | planner, coder | Send images for visual analysis |
| `coder` | planner | Delegate implementation tasks to the coder agent |
| `planner` | coder | Escalate back to the planner for guidance |
| `todos` | planner, coder | Manage an in-memory todo list (add/update/list) |
| `notes` | planner, coder | Read/write a scratchpad for discoveries and context |

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

