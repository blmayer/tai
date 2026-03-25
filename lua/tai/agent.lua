local M = {}

local config = require('tai.config')

if not config.root then
	return M
end

local host = vim.uv.os_uname()

local default_system_prompt = [[
You are a coding agent working in a project. You have read/write access to the
project's codebase in the current folder: ]] .. config.root .. [[

Please work on the tasks given by the user.
]]

M.system_prompt = config.system_prompt or default_system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

return M
