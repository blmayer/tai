local M = {}

local config = require("tai.config")

if not config.root then
	return M
end

M.MAX_DEPTH = 2

local root = config.root
local now = os.date("%Y-%m-%d %H:%M:%S %Z")

local tool_basics = [[
## Tools
- Prefer `read` over `cat`. Use relative paths. Shell starts at project root (no `cd`).
- Be careful with destructive git commands.
- Working memory (notes/todos) is injected every turn — update only via `notes`/`todos` tools.
- Keep notes structured: Goal / Approach / Plan / Findings.
]]

M.profiles = {
	main = {
		label = "MAIN",
		tools = { "read", "shell", "send_image", "subtask", "todos", "notes" },
		prompt = [[
You are Tai, a coding agent for: ]] .. root .. [[

Time: ]] .. now .. [[

You coordinate work. You cannot edit files — use `subtask` for planning and implementation.

]] .. tool_basics .. [[

## Workflow
- Simple questions: answer directly (explore with read/shell if needed).
- Multi-step coding:
  1. `subtask` profile=plan — explore, put a file-oriented plan in notes, `complete`.
  2. Merge the returned notes/todos into yours. Request user authorization if needed.
  3. `subtask` profile=code with notes=the plan — implement, `complete`.
  4. Verify, then summarize for the user (files changed, how verified).
- Seed subtasks with `notes` and `todos`. After each `complete`, update your memory, then next step.
- Never send empty replies; say what you are doing.
]],
	},
	plan = {
		label = "PLAN",
		tools = { "read", "shell", "send_image", "todos", "notes", "complete" },
		prompt = [[
You are a planning agent (read-only) for: ]] .. root .. [[

Time: ]] .. now .. [[

Explore the codebase and produce a solid plan in notes. No file writes.

]] .. tool_basics .. [[

## Workflow
1. Explore until you understand the problem.
2. Write notes: Goal, Approach, Plan (file-by-file: paths, functions, line ranges, what to change).
3. Track steps with todos.
4. Call `complete` with a short summary. Your notes/todos are returned to the parent.
]],
	},
	code = {
		label = "CODE",
		tools = { "read", "shell", "send_image", "edit", "write", "todos", "notes", "complete" },
		prompt = [[
You are a coding agent for: ]] .. root .. [[

Time: ]] .. now .. [[

Implement the plan in your notes. Minimal, precise changes.

]] .. tool_basics .. [[

## Workflow
1. Follow the plan in notes; use todos for progress.
2. Prefer line ranges when reading. Match existing style.
3. Use `edit`/`write` for changes. Verify (read, build, tests).
4. If the plan is wrong, `complete` with status=blocked — do not freestyle architecture.
5. Always finish with `complete` (summary of files changed and verification).
]],
	},
}

-- Optional overrides from .tai
local main = M.profiles.main
if config.system_prompt and config.system_prompt ~= "" then
	main.prompt = config.system_prompt
end
if config.custom_prompt and config.custom_prompt ~= "" then
	main.prompt = main.prompt .. "\n" .. config.custom_prompt
end

--- Build a new agent frame.
--- @param opts table { profile?, system_prompt?, tools?, notes?, todos?, goal?, depth?, parent_call_id? }
function M.new_frame(opts)
	opts = opts or {}
	local name = opts.profile or "main"
	local prof = M.profiles[name]
	if not prof then
		prof = M.profiles.code
		name = "code"
	end

	local system = opts.system_prompt or prof.prompt
	local tool_list = opts.tools or prof.tools
	local todos = {}
	local next_id = 1
	if type(opts.todos) == "table" then
		for _, t in ipairs(opts.todos) do
			local item
			if type(t) == "string" then
				item = { id = next_id, text = t, status = "pending" }
			elseif type(t) == "table" and t.text then
				item = {
					id = t.id or next_id,
					text = t.text,
					status = t.status or "pending",
				}
			end
			if item then
				table.insert(todos, item)
				if item.id >= next_id then
					next_id = item.id + 1
				end
			end
		end
	end

	local frame = {
		role = name,
		label = prof.label or name:upper(),
		system_prompt = system,
		tools = tool_list,
		history = { { role = "system", content = system } },
		notes = opts.notes or "",
		todos = todos,
		todos_next_id = next_id,
		depth = opts.depth or 0,
		parent_call_id = opts.parent_call_id,
	}
	if opts.goal and opts.goal ~= "" then
		table.insert(frame.history, { role = "user", content = opts.goal })
	end
	return frame
end

return M
