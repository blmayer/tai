-- coder.lua: Coder agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local client = require('tai.agents.client')

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
You will receive a list of implementation instructions, your job is to implement them successfully
in the user's codebase. 

You have access to other agents that will help you fullfill the user's goal:
- patcher: takes code changes and formats them in the correct format.
- writer: will inform the user what you want.

COMPLEX TASKS
Sometimes the task will be too complex to be solved at once, in those cases you
can inform the writer of the need, you can also ask the user to run commands
on its machine and send you the output. And add plans.

COMMANDS
Supply the list of commands to be executed on the user's machine for the writer agent.
  - Allowed programs: `]] .. table.concat(config.allowed_commands, '`, `') .. [[`
  - Don't use commands for code changes, use the patcher agent.

RESPONSE FORMAT
After figuring out the needed code changes generate intructions to the patcher agent so it can correctly
apply the changes in the original files. The patcher agent needs detailed instructions of how code was
changed so remember to pass file name, line number and the new code.

To the writer agent you can pass intructions about what the user needs to do, eg. executing commands.
Return only the JSON object, no markdown or code fences (```) in the format:
{
	"patcher": "instructions to the patcher agent (required)",
	"writer": "instructions or text to the writer agent (optional)"
}
]]

function M.task(task, callback)
	log.info("Coder executing task: " .. task)
	provider.request(
		config.coder_model,
		config.coder_thinks,
		M.system_prompt,
		task,
		"json",
		function(data, err)
			callback(data, err)
		end
	)
end

return M
