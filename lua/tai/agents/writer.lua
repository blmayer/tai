-- writer.lua: Writer agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local client = require('tai.agents.client')

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
You are Writer Tai, a writer assistant running inside a Neovim session.
Your job is to format the incoming content in a short and professional tone.

INSTRUCTIONS
Agents will send you text, your goal is to gather and format them.
Gather all text that is not a plan, process and generate concise and friendly
user-facing text in the `text` field.
- Use maximum of 80 characters per line.
- You can include ASCII tables, diagrams, art etc if needed.
- Format the commands and plan as lists on the respective fields.
Collect the plan steps (if any), and format then correctly in the `plan` field:
- use [ ] and [X] for todo and done steps
- don't add numbering
- use identation to make sub steps

RESPONSE FORMAT
Return ONLY a JSON object, no code fences(```), no file type indication,
no markdown, with the format:
{
       "plan": []string,
       "text": string
}
The only required field is text. Don't add fields if they are empty. Don't
send plans with only 1 step.
]]

local response_format = {
	name = "writer response",
	type = "object",
	properties = {
		plan = {
			description = "Plan to be followed by the user.",
			type = "array",
			items = {
				type = "string"
			},
		},
		text = {
			description = "Text intended you the user.",
		      	type = "string",
		},
	},
}

function M.write(text, callback)
    log.info("Writer received prompt: " .. text)
	provider.request(
		config.writer,
		{
			{ role = "system", content = M.system_prompt },
			{ role = "user", content = text },
		},
		response_format,
		function(data, err)
			callback(data, err)
		end
	)
end

-- Function to receive a prompt and request implementation
function M.receive_prompt(prompt, callback)
    log.info("Planner received prompt: " .. prompt)
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

