-- mcp_test.lua
-- Run: nvim --headless -u NONE --noplugin -c "set rtp+=." -c "luafile lua/tai/tests/mcp_test.lua" -c "qa!"

local passed, failed = 0, 0

local function assert_eq(a, b, msg)
	if a == b then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg .. " exp=" .. vim.inspect(a) .. " got=" .. vim.inspect(b))
	end
end

local function assert_true(v, msg)
	if v then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg)
	end
end

local function assert_match(pat, s, msg)
	if type(s) == "string" and s:find(pat) then
		passed = passed + 1
		print("  OK " .. msg)
	else
		failed = failed + 1
		print("  FAIL " .. msg .. " in: " .. tostring(s):sub(1, 300))
	end
end

package.loaded["tai.log"] = {
	debug = function() end,
	info = function() end,
	warning = function() end,
	error = function() end,
}
package.loaded["tai.mcp"] = nil
package.loaded["tai.tools"] = nil

-- Minimal config so tools module loads
package.loaded["tai.config"] = {
	root = "/tmp",
	provider = "mock",
	get_allowed_commands = function()
		return {}
	end,
}

local mcp = require("tai.mcp")
local tools = require("tai.tools")

local server_script = vim.fn.fnamemodify("lua/tai/tests/fixtures/dummy_mcp_server.py", ":p")
if vim.fn.filereadable(server_script) ~= 1 then
	-- try relative to cwd
	server_script = vim.loop.cwd() .. "/lua/tai/tests/fixtures/dummy_mcp_server.py"
end
assert_true(vim.fn.filereadable(server_script) == 1, "dummy server script exists: " .. server_script)

print("\n=== configure + connect stdio ===")
mcp._reset()
mcp.configure({
	dummy = {
		command = "python3",
		args = { server_script },
		denylist = { "secret_tool" },
	},
})

local connected = false
local connect_err = nil
mcp.connect("dummy", function(ok, err)
	connected = ok
	connect_err = err
end)
local wait_ok = vim.wait(10000, function()
	local s = mcp.get_server("dummy")
	return s and (s.status == "connected" or s.status == "error")
end, 50)

assert_true(wait_ok, "connect waited")
local state = mcp.get_server("dummy")
assert_eq("connected", state.status, "status connected (err=" .. tostring(connect_err) .. ")")
assert_true(#state.tools >= 2, "tools listed (>=2, denylist strips secret)")
local names = {}
for _, t in ipairs(state.tools) do
	names[t.name] = true
end
assert_true(names.echo, "has echo")
assert_true(names.add, "has add")
assert_true(not names.secret_tool, "secret_tool denylisted")

print("\n=== status / list_tools / prompt ===")
local status = mcp.status_text()
assert_match("dummy", status, "status has dummy")
assert_match("connected", status, "status shows connected")

local list = mcp.run({ action = "list_tools", server = "dummy" })
assert_match("echo", list, "list_tools echo")
assert_match("add", list, "list_tools add")

local section = mcp.render_prompt_section()
assert_match("MCP Servers", section, "prompt section")
assert_match("echo", section, "prompt lists tools")

print("\n=== call tools ===")
local result, err = mcp.call_tool_sync("dummy", "echo", { text = "hello" }, 10000)
assert_true(err == nil, "echo no err: " .. tostring(err))
assert_match("echo:hello", result, "echo result")

result, err = mcp.call_tool_sync("dummy", "add", { a = 2, b = 3 }, 10000)
assert_true(err == nil, "add no err")
assert_match("5", result, "add result")

result, err = mcp.call_tool_sync("dummy", "secret_tool", {}, 5000)
assert_true(err ~= nil, "denylist blocks call")
assert_match("denylist", err, "denylist error message")

print("\n=== mcp tool runner ===")
local out = mcp.run({ action = "status", server = "dummy" })
assert_match("connected", out, "run status")

local call_out = mcp.run({
	action = "call",
	server = "dummy",
	tool = "echo",
	arguments = { text = "via-tool" },
})
assert_match("echo:via%-tool", call_out, "run call")

print("\n=== update tool def ===")
mcp.update_tool_def(tools.defs)
assert_match("echo", tools.defs.mcp["function"].description, "def updated with tools")

print("\n=== disconnect ===")
local ok, msg = mcp.disconnect("dummy")
assert_true(ok, "disconnect")
assert_eq("disconnected", mcp.get_server("dummy").status, "disconnected status")

mcp._reset()

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	os.exit(1)
end
