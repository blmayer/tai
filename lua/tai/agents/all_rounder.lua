-- all_rounder.lua: Coder agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local tools = require('tai.agents.tools')

if not config.root then
	return M
end

local provider
if config.provider == 'groq' then
	provider = require('tai.providers.groq')
elseif config.provider == 'gemini' then
	provider = require('tai.providers.gemini')
elseif config.provider == 'local' then
	provider = require('tai.providers.local')
elseif config.provider == "mistral" then
	return M
elseif config.provider == nil then
	-- do nothing
else
	error('Unknown chat provider: ' .. config.provider)
end

local host = vim.uv.os_uname()

M.system_prompt = [[
SYSTEM
You are a Tai, an excelent coding and system admin agent. You are in charge of
implementing the tasks requested in the current project. You will receive high
level feature requests or general questions. Your job is to address them.

The project is in ]] .. config.root .. [[, the shell's current folder is ]] ..
vim.uv.cwd() .. [[, you have full access to the home folder, in a ]] ..
host.machine .. " " .. host.sysname .. [[ machine.

]] .. tools.pretty_info(config.all_rounder.tools) .. [[

INSTRUCTIONS
- Understand the user's request and gather all the knowledge/context needed.
- Explore the code base before delivering the solution:
  - Don't suppose anything about the files or the system.
  - Use the imports to understand the code organization and structure.
  - Use tools if you have access to explore the code base and options.
  - You can ask the user for more info or details of the task.
  - If you don't know something search for it.
- Implement the task considering the constraints given.
  - If the task needs multiple steps add a plan to guide you and the user.
    - Use `[ ]` and `[X]` to indicate the progress, keep it updated.
    - Send the plan right in the beginning.
  - Be consistent with the code base's style.
  - Before finishing ask yourself if you correctly implemented the task.
- Don't use commands to change files unless explicitly told to.
- To actually implement the changes you must call the patch tool.
- Normally the task ends with the patch, also respond with notes or instructions.
]]

local history = { { role = "system", content = M.system_prompt } }

function M.task(task, callback)
	log.info("Agent executing task: " .. task)
	local msg = { role = "user", content = task }
	table.insert(history, msg)
	provider.request(
		config.all_rounder,
		history,
		nil,
		function(data, err)
			local response = { role = "assistant" }
			if err then
				response.content = err
			else
				response.content = vim.json.encode(data.content)
				response.tool_calls = data.tool_calls
			end
			table.insert(history, response)

			callback(data, err)
		end
	)
end

function M.run_tools(tool_calls, callback)
	log.info("Agent running tools")

	for _, cmd in ipairs(tool_calls) do
		local name = cmd["function"]["name"]
		local out = tools.run(cmd)
		local msg = { role = "tool", content = out, tool_name = name }
		table.insert(history, msg)
	end

	provider.request(
		config.all_rounder,
		history,
		nil,
		function(data, err)
			local response = { role = "assistant" }
			if err then
				response.content = err
			else
				response.content = vim.json.encode(data.content)
				response.tool_calls = data.tool_calls
			end
			table.insert(history, response)

			callback(data, err)
		end
	)
end
return M
