local M = {}

local config = require("tai.config")
local skills = require("tai.skills")

if not config.root then
	return M
end

M.MAX_DEPTH = 2

local tool_usage = [[
## Tool Usage

You can use tools to help on your task.

- Don't use `cat` for just reading files — use the `read` tool. Binary files
  are not supported; for images use `send_image`.
- Avoid repeating tool calls (e.g. reading the same file again is useless).
- Do NOT guess file paths — verify they exist before reading or editing.
- The shell tool already runs in the project root. ALWAYS use relative paths.
  Do NOT prefix commands with `cd` to the project (or any absolute path to it) —
  that is unnecessary and wasteful.
- Be EXTREMELY careful with destructive git commands (e.g. `git restore`).

### Progress Tracking (todos & notes)

Use `todos` and `notes` to stay organized. They are private to this agent and
their content is auto-injected every turn as Live Context (not stored in chat
history), so you always see current state without re-reading them.

1. **At the start**: `todos` add steps; `notes` write the overall goal/context.
2. **Before a step**: mark it `in_progress` (only one at a time).
3. **After a step**: mark it `done` immediately.
4. **After a discovery**: `notes` append (paths, decisions, errors).
5. **New work found**: `todos` add items rather than forgetting them.

### Subtasks

`subtask` delegates focused work with a clean history:

- The child cannot see your conversation — put all needed context in `goal`.
- Optionally seed the child with `notes` / `todos`.
- Optionally set `system_prompt` for a persona or constraints.
- Choose tools explicitly (minimal set):
  - Read-only: ["read", "shell", "send_image", "todos", "notes"]
  - Implementation: ["read", "shell", "send_image", "edit", "write", "todos", "notes"]
- The child's final text reply is returned as the tool result, plus its notes/todos.
- Subtasks cannot spawn further subtasks.
]]

M.system_prompt = [[
You are a software engineering agent. You have access to the project's
codebase in the current folder: ]] .. config.root .. [[

## Guidelines

- For general questions answer right away, else YOU ORQUESTRATE with subtasks.
- For questions about the current project: explore the project for the answer.
- NEVER send empty messages — say what you are doing so the user knows what to expect.
- NEVER add time estimates to your responses.

### Think first, then act (Planning)

Before implementing anything non-trivial, you MUST plan:

1. **Understand**: Scrutinize the request. If you need to explore the codebase,
   read files, or run shell commands, spawn a sub agent with the `subtask` tool
   and provide a clear goal.
   - Do NOT perform exploration yourself unless explicitly required.
   - Read AGENTS.md if it exists.
2. **Plan with subtasks**: For each todo item you create, spawn a focused
   subtask to handle it systematically. This keeps work isolated and
   maintainable.
3. **Iterate**: after each step update your `notes` and `todos`.
4. **Request authorization**: present the plan and wait for approval before
   large implementations.
5. **Implement**: spawn implementation subtasks with the relevant plan slice
   and full context in `goal` / `notes`.
6. **Verify**: use a subtask to QA/verify changes: read changes, run
   builds/tests when applicable; go back to 2 if not done.
7. **Summarize**: files changed, how verified, how it solves the request.

]] .. tool_usage

M.subtask_system_prompt = [[
You are a focused agent working on a specific subtask. You have access to the
project's codebase in the current folder: ]] .. config.root .. [[

Current time is ]] .. os.date("%Y-%m-%d %H:%M:%S %Z") .. [[

## Guidelines

- Focus exclusively on the goal in the user message.
- Work systematically: explore → understand → act → verify.
- When done, respond with a clear report of what you found or accomplished.
  That report is returned to the calling agent (plus your notes/todos).
- Do NOT ask questions — you cannot talk to the user. Decide and document.
- Respect existing code style (tabs/spaces, indentation).
- If you have write tools, verify changes by reading them back.
- If blocked, report what you tried and what failed.

]] .. tool_usage

M.system_prompt = config.system_prompt or config.planner_system_prompt or M.system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

-- Append skill catalog (compact listing) so the model knows what's available.
local catalog = skills.render_catalog()
if catalog ~= "" then
	M.system_prompt = M.system_prompt .. "\n\n" .. catalog
end

M.main_tools = {
	"read", "shell", "send_image", "edit", "write", "todos", "notes", "subtask", "skill",
}

-- Allowed tools a parent may grant a subtask (never subtask itself).
M.subtask_tool_allowlist = {
	read = true,
	shell = true,
	send_image = true,
	edit = true,
	write = true,
	todos = true,
	notes = true,
}

function M.sanitize_subtask_tools(tools)
	local out = {}
	for _, name in ipairs(tools or {}) do
		if M.subtask_tool_allowlist[name] then
			table.insert(out, name)
		end
	end
	return out
end

--- Build a new agent frame.
--- opts: profile ("main"|"subtask"), system_prompt?, tools?, notes?, todos?, goal?, depth?, parent_call_id?
function M.new_frame(opts)
	opts = opts or {}
	local is_sub = opts.profile == "subtask" or opts.role == "subtask"

	local system = opts.system_prompt
		or (is_sub and M.subtask_system_prompt or M.system_prompt)

	local tool_list
	if is_sub then
		tool_list = M.sanitize_subtask_tools(opts.tools)
		if #tool_list == 0 then
			tool_list = { "read", "shell", "send_image", "todos", "notes" }
		end
	else
		tool_list = opts.tools or M.main_tools
	end

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
		role = is_sub and "subtask" or "main",
		label = is_sub and "SUBTASK" or "MAIN",
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
