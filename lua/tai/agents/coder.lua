-- coder.lua: Coder agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local client = require('tai.agents.client')
local ui = require('tai.ui')
local tools = require('tai.tools')

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
You are a Coder Tai, an excelent coding agent. Your task is to execute coding tasks."

INSTRUCTIONS
You will receive a list of implementation instructions, your job is to generate
a set of instructions to the patcher agent in order to implement them
successfully in the user's codebase. 
Only use the patcher to implement code changes that are complete, don't issue
partial solutions

You have access to other agents that will help you fullfill the user's goal:
- patcher: takes code changes and formats them in the correct format.
- writer: will inform the user what you want.

COMPLEX TASKS
Sometimes the task will be too complex to be solved at once, in those cases you
can inform the writer of the need, you can also ask the user to run commands
on its machine to send you the output.

COMMANDS
Supply the list of commands to be executed on the user's machine for the writer agent.
  - Allowed programs: `]] .. table.concat(config.allowed_commands, '`, `') .. [[`
  - Don't use commands for code changes, use the patcher agent.

TOOLS
You also have access to tools that will help you implement the code changes:
- read_file <file_name>: will send you the content of the file <file_name>

RESPONSE FORMAT
After figuring out the needed code changes generate intructions to the patcher
agent so it can correctly apply the changes in the original files. The patcher
agent needs detailed instructions of how to change the code so remember to pass
file name, line numbers and the new code.

To the writer agent you can pass intructions about what the user needs to do, eg. executing commands.
Return only the JSON object, no markdown or code fences (```) in the format:
{
	"patcher": "instructions to the patcher agent",
	"writer": "instructions or text to the writer agent"
}
]]

local response_format = {
	name = "coder response",
	type = "object",
	properties = {
		patcher = {
			description = "Intructions for the patcher agent",
		      	type = "string",
		},
		writer = {
			description = "Text for the writer agent",
			type = "string",
		},
	},
}

function M.task(task, callback)
	log.info("Coder executing task: " .. task)
	local messages = {
		{ role = "system", content = M.system_prompt },
		{ role = "user", content = task },
	}
	provider.request(
		config.coder,
		messages,
		response_format,
		function(data, err)
			if data.tools then
				ui.show_tool_calls(data.tools)
				local out = tools.run(data.tools)
				table.insert(messages, { role = "tool", content = out })

				provider.request(
					config.coder,
					messages,
					response_format,
					function(data, err)
						callback(data, err)
					end
				)
				return
			end
			callback(data, err)
		end
	)
end

return M
