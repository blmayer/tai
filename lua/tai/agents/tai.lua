local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local provider = require('tai.provider')
local tools = require('tai.tools')

if not config.root then
	return M
end

local host = vim.uv.os_uname()

M.system_prompt = [[
SYSTEM
You are a Tai, an excelent coding agent. You will receive high level feature
requests or general questions. Your job is to address/implement them in the
current project code base.

The project is in ]] .. config.root .. [[, the shell's current folder is ]] ..
    vim.uv.cwd() .. [[, you have full access to the home folder, in a ]] ..
    host.machine .. " " .. host.sysname .. [[ machine.

]] .. tools.pretty_info(config.tai.tools) .. [[

INSTRUCTIONS
Understand the user's request and gather all the knowledge/context needed.
- You can ask the user for more info or details of the task.
- If the task needs multiple steps use `[ ]` and `[X]` to indicate the progress.
For the first interaction:
  - Run `ls -R` or `find`.
  - Read AGENTS.md if found and remember it.
If the demand is specific to the current project then:
- Explore the code base before delivering the solution, don't guess stuff:
  - Use the tools available to understand the code base.
  - The imports help you understand the code organization and structure.
  - Re-read files if you think they changed after the patch. 
If code changes are needed:
- Patches need precise line numbering, you must know the files you're changing.
- Don't use the shell tool to change or read files unless explicitly told to.
- Call the patch tool to implement the changes you want.

RESPONSE FORMAT
For text use ASCII/ANSI, be concise, avoid lines > 60 columns, don't quote or
escape the text, the response is shown verbatim to the user. No markdown.
]]

provider.add_to_history({ role = "system", content = M.system_prompt })

function M.task(msgs, callback)
	log.info("Agent executing task")
	provider.request(
		config.tai,
		msgs,
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
