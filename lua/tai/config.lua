local M = {}
local log = require("tai.log")

M.root = vim.fn.getcwd()
while vim.fn.filereadable(M.root .. "/.tai") == 0 do
	local parent = vim.fn.fnamemodify(M.root, ":h")
	if parent == M.root then
		-- Reached filesystem root without finding .tai
		M.root = nil
		break
	end
	M.root = parent
end

if not M.root then
	return M
end
log.debug("Root is " .. M.root)

-- Provider-side tools (e.g., web_browser for OpenAI)
M.provider_tools = nil

-- Default allowed shell commands
M.default_allowed_commands = {
	cat = true,
	grep = true,
	ag = true,
	rg = true,
	ls = true,
	head = true,
	tail = true,
	wc = true,
	diff = true,
	sort = true,
	uniq = true,
	find = true,
	file = true,
	stat = true,
	date = true,
	echo = true,
	tree = true,
	pwd = true,
	which = true,
	type = true,  -- bash built-in
}

function M.reload()
	if not M.root then
		return false, "no tai root found"
	end

	local f = io.open(M.root .. "/.tai", "r")
	if not f then
		return false, "failed to open .tai"
	end

	local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
	f:close()
	if not ok or type(data) ~= "table" then
		return false, "failed to parse .tai"
	end

	M.model = data.model or M.model
	M.provider = data.provider or M.provider
	M.use_tools = data.use_tools
	if M.use_tools == nil then
		M.use_tools = true
	end
	M.options = data.options
	M.think = data.think or nil
	M.allowed_commands = data.allowed_commands
	M.provider_tools = data.provider_tools

	return true
end

-- Get effective allowed commands (user config or defaults)
function M.get_allowed_commands()
	if M.allowed_commands == nil then
		-- Use defaults
		return M.default_allowed_commands
	end
	return M.allowed_commands
end

M.reload()

return M
