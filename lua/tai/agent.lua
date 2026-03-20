local M = {}

local config = require('tai.config')
local log = require('tai.log')

if not config.root then
	return M
end
local provider = require('tai.' .. config.provider)

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

provider.add_to_history({ role = "system", content = M.system_prompt })



function M.task(msgs, callback)
	log.info("Agent executing task")
	provider.request(
		config,
		msgs,
		nil,
		function(data, err)
			local response = { role = "assistant" }
			if err then
				return callback({ error = err })
			end
			response.content = data.content
			response.tool_calls = data.tool_calls
			response.reasoning_details = data.reasoning_details
			provider.add_to_history(response)
			callback(data)
		end
	)
end

function M.add_to_history(msg)
	provider.add_to_history(msg)
end

function M.clear_history()
	provider.clear_history()
	provider.add_to_history({ role = "system", content = M.system_prompt })
end

return M
