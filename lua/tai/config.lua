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
M.rpm = 60
M.tpm = nil

-- Context persistence configuration
-- Default file is project-scoped (.tai-session.json in project root).
-- Set cache_dir to use a global cache path instead.
M.context = {
  enabled = true,
  cache_dir = nil,
  auto_save = true,
  save_on_shutdown = true,
  file_name = ".tai-session.json"
}

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
	M.options = data.options or {}
	M.stream = data.stream or false
	M.allowed_commands = data.allowed_commands
	M.think = data.think or nil
	M.provider_tools = data.provider_tools
	M.system_prompt = data.system_prompt or nil
	M.custom_prompt = data.custom_prompt or nil
	M.rpm = data.rpm or 60
	M.tpm = data.tpm
	M.auto_approve = data.auto_approve or false

	-- Context persistence settings (keep defaults when `context` is omitted from .tai)
	if data.context then
		if data.context.enabled ~= nil then
			M.context.enabled = data.context.enabled
		end
		if data.context.cache_dir ~= nil then
			M.context.cache_dir = data.context.cache_dir
		end
		if data.context.auto_save ~= nil then
			M.context.auto_save = data.context.auto_save
		end
		if data.context.save_on_shutdown ~= nil then
			M.context.save_on_shutdown = data.context.save_on_shutdown
		end
		if data.context.file_name then
			M.context.file_name = data.context.file_name
		end
	end

	log.debug(string.format(
		"Context config: enabled=%s auto_save=%s save_on_shutdown=%s file_name=%s cache_dir=%s",
		tostring(M.context.enabled),
		tostring(M.context.auto_save),
		tostring(M.context.save_on_shutdown),
		tostring(M.context.file_name),
		tostring(M.context.cache_dir)
	))

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
