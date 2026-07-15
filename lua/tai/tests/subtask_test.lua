-- subtask_test.lua
-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/subtask_test.lua" -c "qa!"

local passed, failed = 0, 0

local function assert_eq(a, b, msg)
	if a == b then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg .. " exp=" .. vim.inspect(a) .. " got=" .. vim.inspect(b)) end
end
local function assert_true(v, msg)
	if v then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg) end
end
local function assert_match(pat, s, msg)
	if type(s) == "string" and s:find(pat) then passed = passed + 1; print("  OK " .. msg)
	else failed = failed + 1; print("  FAIL " .. msg) end
end

package.loaded["tai.config"] = {
	root = "/tmp/test-project",
	provider = "mock",
	model = "test",
	use_tools = true,
	stream = false,
	rpm = 60,
	context = { enabled = false },
	get_allowed_commands = function() return { ls = true } end,
}
package.loaded["tai.log"] = {
	debug = function() end, info = function() end,
	warning = function() end, error = function() end, set_level = function() end, DEBUG = 0,
}

-- force reload
package.loaded["tai.tools.subtask"] = nil
package.loaded["tai.tools"] = nil
package.loaded["tai.agent"] = nil

local tools = require("tai.tools")
local agent = require("tai.agent")
local mem = require("tai.tools.subtask")

print("\n=== subtask tool schema ===")
assert_true(tools.defs.subtask ~= nil, "subtask exists")
assert_true(tools.defs.complete == nil, "complete tool removed")
assert_true(tools.defs.coder == nil, "coder removed")
assert_true(tools.defs.planner == nil, "planner removed")
local p = tools.defs.subtask["function"].parameters
assert_true(vim.tbl_contains(p.required, "goal"), "goal required")
assert_true(vim.tbl_contains(p.required, "tools"), "tools required")
assert_true(p.properties.system_prompt ~= nil, "system_prompt optional field")
assert_true(p.properties.notes ~= nil, "notes optional field")

print("\n=== agent frames ===")
local main = agent.new_frame({ profile = "main" })
assert_eq("MAIN", main.label, "main label")
assert_true(vim.tbl_contains(main.tools, "subtask"), "main has subtask")
assert_true(vim.tbl_contains(main.tools, "edit"), "main has edit")

local child = agent.new_frame({
	profile = "subtask",
	system_prompt = "You are a reviewer only.",
	tools = { "read", "shell", "subtask", "edit" }, -- subtask should be stripped
	goal = "Review foo",
	notes = "seed note",
})
assert_eq("SUBTASK", child.label, "subtask label")
assert_eq("You are a reviewer only.", child.system_prompt, "custom system_prompt")
assert_eq("seed note", child.notes, "seed notes")
assert_true(not vim.tbl_contains(child.tools, "subtask"), "no nested subtask tool")
assert_true(vim.tbl_contains(child.tools, "edit"), "edit allowed")
assert_eq("Review foo", child.history[2].content, "goal as user message")

print("\n=== live context injection ===")
local empty = mem.render_memory({ notes = "", todos = {} })
assert_eq("", empty, "empty memory is empty string")

local frame = { notes = "plan: fix x", todos = { { id = 1, text = "a", status = "pending" } } }
local live = mem.render_memory(frame)
assert_match("Live Context", live, "has Live Context banner")
assert_match("plan: fix x", live, "has notes")
assert_match("#1 %[pending%] a", live, "has todos")

local payload = mem.format_complete("ok", "done", frame)
assert_match("summary: done", payload, "format_complete summary")
assert_match("plan: fix x", payload, "format_complete notes")

print("\n=== notes/todos mutate ===")
local f = { notes = "", todos = {}, todos_next_id = 1 }
assert_match("updated", mem.run_notes({ action = "write", content = "hi" }, f), "write notes")
assert_eq("hi", f.notes, "notes stored")
assert_match("Added", mem.run_todos({ action = "add", text = "t1" }, f), "add todo")
assert_eq(1, #f.todos, "one todo")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
