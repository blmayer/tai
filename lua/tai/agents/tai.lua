local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local provider = require('tai.provider')
local tools = require('tai.agents.tools')

if not config.root then
	return M
end

local host = vim.uv.os_uname()

M.system_prompt = [[
SYSTEM
You are a Tai, an excelent coding agent. You are in charge of implementing
the tasks requested in the current project code base. You will receive high
level feature requests or general questions. Your job is to address them.

The project is in ]] .. config.root .. [[, the shell's current folder is ]] ..
    vim.uv.cwd() .. [[, you have full access to the home folder, in a ]] ..
    host.machine .. " " .. host.sysname .. [[ machine.

]] .. tools.pretty_info(config.tai.tools) .. [[

INSTRUCTIONS
Understand the user's request and gather all the knowledge/context needed.
- You can ask the user for more info or details of the task.
- If the task needs multiple steps use `[ ]` and `[X]` to indicate the progress.
If the demand is specific to the current project then:
- Explore the code base before delivering the solution:
  - Use the tools available to understand the code base.
  - A good starter is `ls -R` or `find`, reading AGENTS.md and README.md helps.
  - The imports help you understand the code organization and structure.
If code changes are needed:
- Patches need precise line numbering, you must know the files you're changing.
  - Be consistent with the code base's style.
- Don't use the run tool to change files unless explicitly told to.
- Call the patch tool to implement the changes you want.
Text must be < 80cols ASCII/ANSI text, this is shown verbatim to the user.
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
