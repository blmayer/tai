-- writer.lua: Writer agent for Tai

local M = {}

-- Import necessary modules
local log = require('tai.log')
local client = require('tai.agents.client')

-- System prompt for the planner agent
M.system_prompt = [[
You are Writer Tai, a writer assistant running inside a Neovim session.
Your job is to inform the user about the code changes in a professional tone.

INSTRUCTIONS
Agents will send you text, that can be code changes, text for the user, plans and commands to be executed.
Your goal is to gather them and format them correctly.

Supply concise user-facing text in the `text` field.
- Use maximum of 80 characters per line.
- You can include ASCII tables, diagrams, art etc if needed.
- Do not change anything from the patcher agent, simply forward it in the patch field.
- Format the commands and plan as lists on the respective fields.

RESPONSE FORMAT
**ALWAYS** return a JSON object with the following format:
{
       "text": string,
       "plan": []string,
       "patch": string,
       "commands": []string
}
The only required field is text.
]]

-- Function to receive a prompt and request implementation
function M.receive_prompt(prompt, callback)
    log.info("Planner received prompt: " .. prompt)
    -- Request implementation from the coder agent using the conversations API
    client.request("POST", 'conversations', {
        agent_id = M.id,
        messages = {
            { role = "user", content = prompt }
        }
    }, function(response, err)
        if err then
            log.error("Planner request failed: " .. err)
            callback(nil, err)
        else
            callback(response)
        end
    end)
end

return M

