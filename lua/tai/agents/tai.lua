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

]] .. tools.pretty_info(config.tai.tools) .. [[

INSTRUCTIONS
Understand the user's request and gather all the knowledge/context needed.
- You can ask the user for more info or details of the task.
- Don't return xml tags for plain text. Don't use markdown, only ASCII/ANSI.
- If the task needs multiple steps use `[ ]` and `[X]` to indicate the progress.
If the demand is specific to the current project then:
- Explore the code base before delivering the solution:
  - Use the tools available to understand the code base.
  - A good starter is `ls -R` or `find`. Reading AGENTS.md can help too.
  - The imports help you understand the code organization and structure.
If code changes are needed:
- Implement the task considering the constraints given.
  - Be consistent with the code base's style.
- You must know the contents before changing a file.
- Don't use the run tool to change files unless explicitly told to.
- Call the patch tool to implement the changes you want.
]]

provider.add_to_history({ role = "system", content = M.system_prompt })

function M.task(task, callback)
	log.info("Agent executing task: " .. task)
	provider.request(
		config.tai,
		{ role = "user", content = task },
		nil,
		function(data, err)
			local response = { role = "assistant" }
			if err then
				response.content = err
			else
				response.content = vim.json.encode(data.content)
				response.tool_calls = data.tool_calls
			end
			provider.add_to_history(response)

			callback(data, err)
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
