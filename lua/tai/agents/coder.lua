-- coder.lua: Coder agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local ui = require('tai.ui')
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
You are a Coder Tai, an excelent coding agent. You are in charge of implementing
the tasks requested in the current project. You will receive high level
instructions from the software architect that should be a starting point for
the implementation. Your job is to correctly generate and implement code
changes for the code base.

You have full access to the project's code base, and a terminal in your machine,
but you can't apply code changes.

You have access to other agents that will help you fullfil the task:
- patcher: will take your code changes and apply them in the code base.
- writer: will inform the user what you want.
After figuring out the needed code changes generate intructions to the patcher
agent so it can correctly apply the changes in the original files.

]] .. tools.pretty_info(config.coder.tools) .. [[

INSTRUCTIONS
Consider these guiding tips:
- Understand the code base by reading files and running commands you need.
- You can use multiple turns to run tools or asking the user for clarification.
- Consider the imports to understand the code organization.
- Implement the task considering the constraints given.
- Before finishing ask yourself if you correctly implemented the task.
- Separate the changes by file making it clear what have changed.
- Communicate the patcher agent of your changes.
- If you receive a plan, stick to it, but you can add more detailed steps.
The patcher agent will create an ed script from the code changes you send. So
make sure to explain your changes, including:
- the file name
- line numbers
- the new content
Only use the patcher to implement code changes that are complete, don't issue
partial solutions. If no changes are needed don't call it. The only thing the
pacher can do is to create the patch, it can't run commands or code.

To the writer agent you can pass intructions about what the user needs to do,
eg. executing commands that are not allowed, or general comments/details.

COMPLEX TASKS
Sometimes the task will be too complex to be solved at once, in those cases you
can inform the writer agent of the need, you can also ask the user to run commands
on its machine to send you the output.

RESPONSE FORMAT
Return ONLY a JSON object, no markdown, no code fences (```), with the format:
{
	"patcher": string,
	"writer": string
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
		function(data, err) callback(data, err) end
	)
end

function M.run_tools(tool_calls, callback)
	log.info("Planner running tooks")

	local out = tools.run(tool_calls)
	local messages = {
		{ role = "system", content = M.system_prompt },
		{ role = "tool", content = out },
	}

	provider.request(
		config.coder,
		messages,
		response_format,
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
