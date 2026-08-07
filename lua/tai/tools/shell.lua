local M = {}
local log = require('tai.log')
local tools_io = require("tai.tools.io")

-- Export limit_output from io module
M.limit_output = tools_io.limit_output

function M.unsafe_command(cmd)
	log.debug("Running `" .. cmd .. "`")

	-- Check for disallowed redirect operators.
	-- Note: the harness already appends `2>&1`; models often add `2>/dev/null`
	-- which trips this check — that is intentional, not a quoting bug.
	if cmd:match("[><]") then
		log.debug("Command contains redirects, which are not allowed: " .. cmd)
		return "[sys] Redirects (>, <, >>, <<, 2>/dev/null, etc.) are not allowed. Stderr is already captured; omit redirects."
	end

	local config = require("tai.config")
	local allowed = config.get_allowed_commands()

	-- Extract the base command (first word). Paths like /usr/bin/ssh use basename.
	local base_cmd = cmd:match("^%s*(%S+)")
	if base_cmd then
		base_cmd = base_cmd:match("([^/]+)$") or base_cmd
		-- Drop a leading env assignment like FOO=bar cmd
		if base_cmd:find("=") then
			base_cmd = cmd:match("^%s*%S+=%S+%s+(%S+)")
			if base_cmd then
				base_cmd = base_cmd:match("([^/]+)$") or base_cmd
			end
		end
	end
	if not base_cmd or not allowed[base_cmd] then
		return "Command " .. tostring(base_cmd or "?") .. " is not allowed."
	end

	return false
end

function M.exec_command(cmd)
	log.debug("Executing `" .. cmd .. "`")

	local env = {}
	for _, name in ipairs({ "PATH" }) do
		env[#env + 1] = name .. "=" .. (os.getenv(name) or "")
	end

	local env_prefix = ""
	for _, v in ipairs(env) do
		local name, value = v:match("^([^=]+)=(.*)$")
		if name and value then
			env_prefix = env_prefix .. name .. "='" .. value:gsub("'", "'\\''") .. "' "
		end
	end

	local full_cmd = env_prefix .. cmd .. " 2>&1"
	local handle = io.popen(full_cmd, "r")
	if not handle then
		return nil, "Failed to run command"
	end

	local output = handle:read("*a")
	handle:close()

	if not output then
		output = cmd .. "` returned null"
	end

	return M.limit_output(output, "shell")
end

return M
