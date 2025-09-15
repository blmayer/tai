-- planner.lua: Planner agent for Tai

local M = {}

-- Import necessary modules
local log = require('tai.log')
local client = require('tai.agents.client')

-- System prompt for the planner agent
M.system_prompt = [[
You are Planner Tai, a coding assistant running inside a Neovim session.
Your job is to coordinate agents to fullfill the user's prompts.

INSTRUCTIONS
Users will send coding tasks/questions, your goal is to fullfill them with success.
ONLY propose steps that solves the issue, don't suppose anything.

You have access to other agents that will assist you to reach the user's goals:
- coder: knows how to code, it will take your instructions and implement them.
- patcher: takes code changes and formats them in ed script format.
- writer: will inform the user about the changes in a professional and efficient way.

UNDERSTANDING NEEDED CODE CHANGES
Understand the problem and the path to the solution and generate a detailed set of
instructions to the coder agent so that:
- the coder agent can know exactly what to do
- will respect the restrictions if any
- will be able to write code to fullfill the user's goal

USING PLANS
For solutions that will need many steps that includes interaction from the user generate
a step by step plan and pass it to the writer agent, so it will forward it to the user.
Use the plan created to guide you and the agents towards the goal.
]]

-- Function to receive a prompt and request implementation
function M.receive_prompt(prompt, callback)
    log.info("Planner received prompt: " .. prompt)
    if M.conversation_id then
	    client.request("POST", 'conversations/' .. M.conversation_id, {
		agent_id = M.id,
		inputs = prompt,
	    }, function(response, err)
		if err then
		    log.error("Planner request failed: " .. err)
		    callback(nil, err)
		else
		    callback(response)
		end
	    end)
    else
	    client.request("GET", 'conversations', nil, function(response, err)
		if err then
		    log.error("Planner request failed: " .. err)
		    callback(nil, err)
		else
			if #response > 0 then
				M.conversation_id = response[1]["id"]
			else
		    callback(response)
		end
	    end)
	    client.request("POST", 'conversations', {
		agent_id = M.id,
		inputs = prompt,
	    }, function(response, err)
		if err then
		    log.error("Planner request failed: " .. err)
		    callback(nil, err)
		else
		    callback(response)
		end
	    end)
    end
end

return M
