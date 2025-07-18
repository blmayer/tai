# tai.nvim + tai

> A simple Neovim plugin paired with a Unix socket server to send text selections or prompts and receive responses, enabling interactive workflows from within Neovim.


## Features

### Automatic File Summarization

The server creates summaries of your files and caches them to improve response relevance and speed on repeated queries.


### Groq Integration

This project uses the Groq API for processing requests. Make sure to set the environment variable:

      GROQ_API_KEY=your_api_key_here


### Caching

Summaries and previous interactions are cached on the server side to optimize performance and reduce API calls.


### Integrated workflow

Uses intuitive bindings that make it easy to query and interact with your code or text without leaving Neovim.


## Project Components

### 1. **tai.nvim** (Neovim Plugin)

- Connects to a Unix socket (`/tmp/tai.sock`) on startup
- Sends operator-motion or visual selections to the server
- Optionaly prompts for freeform input
- Sends file context along with prompts
- Displays server responses in a bottom split buffer
- Minimal, dependency-free Lua code for Neovim


### 2. **tai** (Go Unix Socket Server)

- Listens on a Unix domain socket (`/tmp/tai.sock`)
- Receives text payloads from the Neovim plugin
- Processes requests asynchronously (you can customize the processing)
- Sends responses back to the plugin in one write operation
- Designed for easy integration with any backend logic or AI models


## Installation

### Neovim Plugin

Place the plugin code at:

    ~/.config/nvim/lua/tai.lua

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


### Server

Build and run the Go server:

    go build -o tai .
    ./tai -c

Make sure it creates and listens on `/tmp/tai.sock`.


## Usage

- Use `gT` plus a motion to send a text selection to the server.
- Use `gP` plus a motion to send a text selection **with** a prompted input.
- Use insert mode `<leader>ti` to prompt input and send.
- Use insert mode `<leader>tf` to prompt input and send along with the full file context.


## Requirements

- Neovim 0.5 or newer
- Unix-like OS with Unix domain socket support
- Go compiler to build the server


## License

MIT License

