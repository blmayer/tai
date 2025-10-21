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

M.system_prompt = [[
SYSTEM
You are a Tai, an excelent coding agent. You are in charge of implementing
the tasks requested in the current project. You will receive high level
feature requests or general questions. Your job is to address them.

You have full access to the project's code base, and a terminal in your machine.

]] .. tools.pretty_info(config.coder.tools) .. [[

INSTRUCTIONS
Consider these guiding tips:
- Understand the code base by reading files and running commands you need.
  - Consider the imports to understand the code organization.
  - Use the tools if you have access: start by looking at the current folder.
  - You can use multiple turns, e.g. listing files, then reading a file.
  - You can ask the user for more info.
- Implement the task considering the constraints given.
- Before finishing ask yourself if you correctly implemented the task.
- To finish you must create the patch using the patch tool.
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
			table.insert(
				history,
				{
					role = "assistant",
					content = vim.json.encode(data.content),
					tool_calls = data.tool_calls,
				}
			)
			callback(data, err)
		end
	)
end

function M.run_tools(tool_calls, callback)
	log.info("Agent running tools")

	local out = tools.run(tool_calls)
	local msg = { role = "tool", content = out }
	table.insert(history, msg)

	provider.request(
		config.all_rounder,
		history,
		nil,
		function(data, err)
			table.insert(
				history,
				{
					role = "assistant",
					content = vim.json.encode(data.content),
					tool_calls = data.tool_calls,
				}
			)
			callback(data, err)
		end
	)
end
return M
