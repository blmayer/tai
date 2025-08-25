> This project contains two utilities: A simple Neovim plugin to send text selections or prompts and receive responses, enabling interactive workflows from within Neovim and a command line program to integrate AI into your shell.


# Features


## Groq Integration

This project uses the Groq API for processing requests. Make sure to set the environment variable:

      GROQ_API_KEY=your_api_key_here


## Integrated workflow

Uses intuitive bindings that make it easy to query and interact with your code or text without leaving Neovim.


# Project Components

1. **tai.nvim** (Neovim Plugin)

- Sends operator-motion or visual selections to the server
- Optionaly prompts for freeform input
- Sends file context along with prompts
- Displays server responses in a split buffer
- Minimal, dependency-free Lua code for Neovim
- Can run commands with safety validation
- Follows plans for complex tasks


2. **tai** (CLI)

- Receives text payloads and standard input
- Sends responses back to the standard output
- Designed for easy integration with shell pipelines


## tai.nvim


### Installation

Place the plugin code at:

    ~/.config/nvim/lua/tai/

A proper plugin is install method is underway.

and load it in your `init.lua`:

    local tai = require("tai")

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
      vim.schedule(tai.prompt_input)
    end, { noremap = true })

    vim.keymap.set("n", "<leader>tf", function()
      vim.schedule(tai.prompt_full_file)
    end, { noremap = true })

    vim.keymap.set("n", "<C-w><C-t>", function()
    	require("tai").toggle_chat_window()
    end, { noremap = true })

### Usage

- Use `gT` plus a motion to send a text selection to the server.
- Use `gP` plus a motion to send a text selection **with** a prompted input.
- Use insert mode `<leader>ti` to prompt input and send.
- Use insert mode `<leader>tf` to prompt input and send along with the full file context.
- To toggle the chat window use `Ctrl+w Ctrl+t`


### Requirements

- A `.tai` file in your project root, if not found tai will not work.
- Neovim 0.5 or newer
- Unix-like OS
- curl


## tai


### Building

Clone this repo and run:

    go build -o tai .

Move the binary to a folder in your path for best results.


## License

MIT License

