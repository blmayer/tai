# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint
  - `config.lua` — defaults + user configuration
  - `agent.lua` — profiles (main/plan/code), system prompts, `new_frame`
  - `providers.lua` / `provider_common.lua` — provider adapters
  - `tools.lua` — tool schemas + execution helpers (notes/todos/memory)
  - `ui.lua` — agent stack, chat UI, tool runner, subtask folds
  - `context.lua` — session persistence (stack + chat_lines)
  - `log.lua` — logging
- `www/` — static website assets
- `README.md` — user documentation
- `TODO.md` — rough roadmap / scratchpad

## Agent harness (runtime)

```
stack[1] = MAIN frame (history + notes + todos)
stack[2] = optional PLAN or CODE subtask

each request:
  system = base_prompt + render_memory(frame)   -- ephemeral, not stored
```

- `subtask` pushes a frame and opens `{{{ SUBTASK …`
- `complete` pops, closes `}}}`, returns summary+notes+todos as the parent tool result
- Max depth: 2

## How to orient quickly (when debugging)

1. Start at the entrypoint: `lua/tai/init.lua`.
2. Trace configuration: `config.lua` → where it’s read/merged.
3. Trace a request:
   - frame + prompts: `agent.lua`
   - injection + stack: `ui.lua` (`prepare_messages`, `finish_subtask`)
   - provider formatting: `providers.lua`
   - tools: `tools.lua`

## Common tasks

- **Add a new provider**
  - Extend `providers.lua` (or the provider registry there).
  - Update `README.md` and `www/index.html`.

- **Add/adjust a tool**
  - Update `lua/tai/tools.lua` (schema + runner).
  - Give the tool to the right profile(s) in `agent.lua`.
  - Wire execution in `ui.lua` `run_tools` if needed.
  - Update docs.

- **Add provider-side tools (e.g., web_browser)**
  - Add the tool name to `config.provider_tools` in `.tai`.
  - Document in README / www.

## Development notes

- Prefer small, explicit Lua. Avoid new dependencies.
- Keep system prompts compact (small models).
- Working memory must stay request-ephemeral (never append into history).

(Agent reminder) You are editing the Tai plugin’s own code—double-check changes for regressions.
