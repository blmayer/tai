-- coder.lua: Coder agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
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
You are a Coder Tai, an excelent coding agent. Your goal is to execute coding tasks."

INSTRUCTIONS
You will receive the task definition, your job is to implement them in the
user's codebase. For that think like an experienced programmer:
- read the files you need
- consider the imports to understand the organization
- implement the task considering the constraints
- communicate the patcher agent of your changes

COMPLEX TASKS
Sometimes the task will be too complex to be solved at once, in those cases you
can inform the writer agent of the need, you can also ask the user to run commands
on its machine to send you the output.

TOOLS
You also have access to tools that will help you implement the code changes:
- read_file <file_name>: will send you the content of the file <file_name>
- run <command>: asks the user to run <command> in a shell and returns the output.

You have access to other agents that will help you fullfil the user's goal:
- patcher: takes code changes and formats them in the correct format.
- writer: will inform the user what you want.
After figuring out the needed code changes generate intructions to the patcher
agent so it can correctly apply the changes in the original files.
The patcher agent will create an ed script from the code changes you send. So
make sure to explain your changes, including:
- the file name
- line numbers
- the new content
Only use the patcher to implement code changes that are complete, don't issue
partial solutions.
To the writer agent you can pass intructions about what the user needs to do, eg. executing commands, or general comments.

RESPONSE FORMAT
Return ONLY a JSON object, no markdown, no code fences (```), with the format:
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
