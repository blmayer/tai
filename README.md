# tai.nvim

> This project contains a **simple Neovim plugin** to send text selections or prompts and receive responses, enabling **interactive workflows** from within Neovim.

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
    	require("tai").toggle_chat_window()
    end, { noremap = true })


## Usage

The default mappings will give you:

- Use `gT` plus a motion to send a text selection to the server.
- Use `gP` plus a motion to send a text selection **with** a prompted input.
- In normal mode `<leader>ti` to prompt input and send.
- To toggle the chat window use `Ctrl+w Ctrl+t`
- Use `<leader>tr` to clear history.


## Requirements

- A `.tai` JSON file in your project root, if not found tai will not work.
- Neovim 0.5 or newer
- Unix-like OS
- curl

The .tai file supports the following fields:
- model: The model used for chat completions.
- provider: The API provider (e.g., 'mistral', 'groq', 'gemini', 'local').
- options: Options sent to the model, specific for each provider.


## License
This project is licensed under the MIT License.

