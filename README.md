# tai.nvim

> This project contains a **simple Neovim plugin** to send text selections or prompts and receive responses, enabling **interactive workflows** from within Neovim.

<a href="https://dotfyle.com/plugins/blmayer/tai">
	<img src="https://dotfyle.com/plugins/blmayer/tai/shield?style=flat" />
</a>

## Providers

This project is compatible with the Groq, Gemini, Mistral, Z.AI, OpenAI, Openrouter, StepFun, Local (Ollama) and Minimax APIs for processing requests. Make sure to set the correct environment variable:

       GROQ_API_KEY=your_api_key_here

for Groq, or:

       GEMINI_API_KEY=your_api_key_here

for Gemini, or:

       ZAI_API_KEY=your_api_key_here

for Z.AI, or:

       OPENAI_API_KEY=your_api_key_here

for OpenAI, or:

       MINIMAX_API_KEY=your_api_key_here

for Minimax, or configure a local Ollama server (localhost:11434).

## Integrated workflow

Uses intuitive bindings that make it easy to query and interact with your code or text without leaving Neovim.

- Opens a side panel to display input and responses
- Minimal, dependency-free Lua code for Neovim
- Can run commands with safety validation
- Follows plans for complex tasks


## Installation

### Plugin Managers

#### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  "blmayer/tai",
  opts = {},
  -- Optional: keybindings
  keys = {
    { "<leader>ti", "<cmd>Tai chat<cr>", desc = "Open Tai chat" },
    { "<leader>tr", "<cmd>Tai clear<cr>", desc = "Clear Tai history" },
    { "<C-w><C-t>", "<cmd>Tai toggle<cr>", desc = "Toggle Tai window" },
  },
}
```

#### [Packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use("blmayer/tai")
```

#### [vim-plug](https://github.com/junegunn/vim-plug

```vim
Plug "blmayer/tai"
```

#### Manual Installation

Place the plugin code at:

    ~/.config/nvim/lua/tai/

and load it in your `init.lua`:

    local tai = require("tai")
    tai.setup({})

The plugin also provides the `:Tai` command for common operations:

- `:Tai chat` - Open the chat window
- `:Tai toggle` - Toggle the chat window
- `:Tai clear` - Clear conversation history
- `:Tai reload` - Reload configuration

## Configuration

tai reads configuration from a `.tai` JSON file in your project root. The following options are supported:

- `model`: The model used for chat completions (e.g., "llama-3.1-70b-versatile", "gemini-2.0-flash").
- `provider`: The API provider - one of: `groq`, `gemini`, `mistral`, `z_ai`, `openai`, `openrouter`, `stepfun`, `local`, `minimax`.
- `options`: Provider-specific options passed to the API (e.g., `temperature`, `max_tokens`). See your provider's API docs.
- `provider_tools`: Array of provider-side tools (e.g., `["web_browser"]` for OpenAI).
- `use_tools`: Boolean to enable/disable agent tools. Default is `true`. When `false`, the agent will not have access to file read/write or shell command tools.
- `think`: Enable extended thinking/reasoning for models that support it.
- `allowed_commands`: Override the default list of allowed shell commands. By default, tai allows: `cat`, `grep`, `ag`, `rg`, `ls`, `head`, `tail`, `wc`, `diff`, `sort`, `uniq`, `find`, `file`, `stat`, `date`, `echo`, `tree`, `pwd`, `which`, `type`.

Example `.tai` file:

```json
{
	"provider": "groq",
	"model": "llama-3.1-70b-versatile",
	"options": {
		"temperature": 0.7,
		"max_tokens": 4096
	},
	"use_tools": true,
	"allowed_commands": {
		"git": true,
		"npm": true,
		"cargo": true
	}
}
```

## Requirements

- Neovim 0.10+
- curl (for API calls)
- An API key for your chosen provider

## License

This project is licensed under the MIT License.
