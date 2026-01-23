# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Golden rules

- Make the *smallest, most focused* change that solves the user’s request.
- Prefer root-cause fixes over surface patches.
- Keep style consistent with surrounding code.
- Run a relevant check (tests/lint or a minimal smoke run) before finishing.
- When modifying behavior, update docs (`README.md`) if the user-facing contract changes.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint
  - `config.lua` — defaults + user configuration
  - `agent.lua` — orchestration of chat/task flow
  - `provider.lua` and `openai.lua` / `groq.lua` / `openrouter.lua` / `mistral.lua` / `gemini.lua` — provider adapters
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
   - provider selection + request formatting: `provider.lua` + specific provider file
   - tool calls: `tools.lua`
   - user-visible output: `ui.lua`

## Common tasks

- **Add a new provider**
  - Create `lua/tai/<provider>.lua` similar to existing providers.
  - Wire it into `provider.lua` (registry/selection).
  - Document config keys in `README.md`.

- **Add/adjust a tool**
  - Update `lua/tai/tools.lua`.
  - Ensure the tool schema and the execution function stay in sync.
  - Consider UX impact (how results are shown) in `ui.lua`.

- **Change default behavior**
  - Update defaults in `config.lua`.
  - If user-facing, update `README.md`.

## Development notes

- This repo is primarily Lua (Neovim plugin). Keep code idiomatic Lua.
- Prefer explicit, readable code over cleverness.
- Avoid adding new dependencies unless necessary.

## Quick sanity checks

There may not be a formal test suite. At minimum:

- Ensure Lua files parse (no syntax errors).
- If you can, run Neovim and load the plugin to smoke-test the affected flow.

(Agent reminder) You are editing the Tai plugin’s own code—double-check changes for regressions.
