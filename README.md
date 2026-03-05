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

Place the plugin code at:

    ~/.config/nvim/lua/tai/

A proper plugin is install method is underway.

and load it in your `init.lua`:

    local tai = require("tai")
    tai.setup({})

    _G.tai_operator_send = tai.operator_send
    _G.tai_operator_send_with_prompt = tai.operator_send_with_prompt
    
    vim.keymap.set("n", "gT", function()
      vim.cmd("set operatorfunc=v:lua.tai_operator_send")
      vim.api.nvim_feedkeys("g@", "n", false)
    end)

    vim.keymap.set("n", "gP", function()
      vim.cmd("set operatorfunc=v:lua.tai_operator_send_with_prompt")
      vim.api.nvim_feedkeys("g@", "n", false)
    end)

    vim.keymap.set("n", "<leader>ti", function()
      vim.schedule(tai.chat)
    end, { noremap = true })

    vim.keymap.set("n", "<leader>tr", function()
      vim.schedule(tai.clear)
    end, { noremap = true })

    vim.keymap.set("n", "<C-w><C-t>", function()
      vim.schedule(tai.toggle)
    end, { noremap = true })

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
