local M = {}
local config = require("tai.config")

function M.validate(cmd)
	local parts = vim.split(cmd, "%s+")
	if #parts == 0 then return false end

	local base = parts[1]:match("^([^/]+)$")
	if not base or not config.allowed_commands[base] then
		return false
	end

	for _, arg in ipairs(parts) do
		if arg:sub(1, 1) == "-" then
			goto continue
		end
		if arg:sub(1, 1) == "/" then
			return false
		end
		if arg:match("%.%.") then
			return false
		end
		if arg:match("[*?]") then
			return false
		end
		::continue::
	end

	return true
end

function M.run(cmd)
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

	return output
end

return M
