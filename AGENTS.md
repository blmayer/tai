# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint
  - `config.lua` — defaults + user configuration
  - `agent.lua` — orchestration of chat/task flow
  - `openai.lua` / `groq.lua` / `openrouter.lua` / `mistral.lua` / `gemini.lua` — provider adapters
  - `tools.lua` — tool definitions + tool execution plumbing
  - `ui.lua` — buffers/windows and UX
  - `log.lua` — logging
- `www/` — static website assets
- `README.md` — user documentation
- `TODO.md` — rough roadmap / scratchpad

## How to orient quickly (when debugging)

1. Start at the entrypoint: `lua/tai/init.lua`.
2. Trace configuration flow: `config.lua` → where it’s read/merged.
3. Trace a request:
   - prompt/task setup: `agent.lua`
   - provider selection + request formatting: specific provider file
   - tool calls: `tools.lua`
   - user-visible output: `ui.lua`

## Common tasks

- **Add a new provider**
  - Create `lua/tai/<provider>.lua` similar to existing providers.
  - Update `README.md` with document config keys and provider list.
  - Update `www/index.html` page to keep it in sync.

- **Add/adjust a tool**
  - Update `lua/tai/tools.lua`.
  - Add tool details to system prompt in `lua/tai/agent.lua`
  - Ensure the tool schema and the execution function stay in sync.
  - Consider UX impact (how results are shown) in `lua/tai/ui.lua`.

- **Change default behavior**
  - Update defaults in `config.lua`.
  - If user-facing, update `README.md`.

## Development notes

- This repo is primarily Lua (Neovim plugin). Keep code idiomatic Lua.
- Prefer explicit, readable code over cleverness.
- Avoid adding new dependencies unless necessary.

(Agent reminder) You are editing the Tai plugin’s own code—double-check changes for regressions.
