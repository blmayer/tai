# Tai project (agent notes)

Tai is a Neovim plugin (Lua) that integrates an LLM assistant into your coding workflow.
This repo also includes a small static website under `www/`.

These notes are intended for **automated coding agents** working in this repository.

## Repository layout

- `lua/tai/` — Neovim plugin implementation (all core logic)
  - `init.lua` — plugin entrypoint (`setup`, `chat`, `stop`, …)
  - `config.lua` — defaults + `.tai` project config
  - `agent.lua` — main/subtask system prompts, `new_frame`, tool allowlists
  - `providers.lua` / `provider_common.lua` — provider adapters
  - `tools.lua` — tool **schemas** + re-exports
  - `tools/` — implementation modules (`io`, `shell`, `edit`, `subtask`)
  - `ui.lua` — facade wiring ui modules
  - `ui/core.lua` — stack, continue loop, tool runner, chat UI
  - `ui/session.lua` — persistence helpers (if used)
  - `ui/tools.lua` — alternate/legacy tool-runner path
  - `context.lua` — session file load/save
  - `log.lua` — logging
- `plugin/tai.lua` — optional autoload + `:Tai` user command
- `www/` — static website assets
- `README.md` — user documentation
- `TODO.md` — rough roadmap / scratchpad

## Agent harness (runtime)

```
stack[1] = MAIN frame (history + notes + todos)
stack[2] = optional SUBTASK (goal, tools, system_prompt?, seed notes/todos)

each request (ephemeral):
  system = base_prompt
         + Live Context (notes/todos)   -- never stored in history

subtask ends when the child returns with no tool_calls:
  finish_subtask → parent tool result = summary + child notes + todos
  UI fold closes (}}} )
```

- Main tools: `read`, `shell`, `send_image`, `edit`, `write`, `todos`, `notes`, `subtask`
- Child tools: only those listed in `subtask.tools` (never `subtask` itself)
- Max depth: 2
- No `complete` tool — final assistant text is the handoff

## How to orient quickly (when debugging)

1. Entrypoint: `lua/tai/init.lua` → `ui.init` / `ui.continue`.
2. Config: `config.lua` (needs `.tai` walking up from cwd).
3. Request path:
   - prompts/frames: `agent.lua`
   - Live Context: `tools/subtask.lua` `render_memory` + `ui/core.lua` `prepare_messages`
   - tool execution: `ui/core.lua` `run_tools`
   - provider: `providers.lua`

## Common tasks

- **Add a new provider**
  - Extend `providers.lua`.
  - Update `README.md` and `www/index.html`.

- **Add/adjust a tool**
  - Schema in `lua/tai/tools.lua`.
  - Implementation under `lua/tai/tools/` (or inline).
  - Wire in `ui/core.lua` `run_tools`.
  - Update allowlists in `agent.lua` if subtasks may use it.
  - Update README / www.

- **Change system prompts**
  - `lua/tai/agent.lua` (`system_prompt`, `subtask_system_prompt`, `tool_usage`).

- **Provider-side tools (e.g. web_search)**
  - `.tai` field `provider_tools`.
  - Document in README / www.

## Development notes

- Prefer small, explicit Lua. Avoid new dependencies.
- Keep system prompts compact (small models).
- Live Context must stay request-ephemeral (never append into history).
- Requires Neovim 0.10+ (`vim.uv`).

(Agent reminder) You are editing the Tai plugin’s own code—double-check changes for regressions.
