-- planner.lua: Planner agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local client = require('tai.agents.client')

if not config.root then
	return M
end

-- Load the appropriate provider
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
You are Planner Tai, a coding assistant running inside a Neovim session.

Your job is to coordinate agents to fullfil the user's prompts.

INSTRUCTIONS
Users will send coding tasks or questions, your goal is to fullfill them with success.
You have access to other agents that will assist you to reach the user's goals:
- coder: knows how to code, it will take your instructions and implement them.
- writer: will respond to the user using the correct format.
After your response the other agents will be called.

UNDERSTANDING NEEDED CODE CHANGES
Understand the user request and the problem, think on the path to the solution
and, generate a detailed set of instructions to the coder agent so that:
- the coder agent can know what to do.
- will be able to write code to fullfil the user's goal.
Only call the coder agent if code changes are needed.

USING PLANS
For solutions that will need many steps that includes interaction from the user generate
a step by step plan and send it to the writer agent, so it will forward it to the user.
Use the plan created to guide you and the agents towards the goal.

USING THE WRITER AGENT
Write to the writer agent whatever you want the user to receive.

RESPONSE FORMAT
Return only a JSON object, no code fences(```), no markdown, with the format:
{
	"coder": "instructions to the coder agent",
	"writer": "instructions or text to the writer agent (required)"
}
Note: don't add the field "coder" if unecessary.
]]

function M.plan(prompt, callback)
	log.info("Planner received prompt: " .. prompt)
	provider.request(
		config.planner_model,
		config.planner_thinks,
		M.system_prompt,
		prompt, 
		"json",
		function(data, err) 
			callback(data, err)
		end
	)
end

-- Function to receive a prompt and request implementation
function M.receive_prompt(prompt, callback)
	log.info("Planner received prompt: " .. prompt)
	if M.conversation_id then
		log.debug("Using existing conversation id: " .. M.conversation_id)
		client.request("POST", 'conversations/' .. M.conversation_id, {
			inputs = prompt,
			handoff_execution = "server"
		}, function(response, err)
			if err then
				log.error("Planner request failed: " .. err)
				callback(nil, err)
				return
			end

			local outputs = response["outputs"]
			local content = outputs[#outputs]["content"]
			if not content then
				callback(nil)
				return
			end
			local res = content
			callback(vim.json.decode(res))
		end)
		return
	end

	log.debug("conversarion id not set")
	client.request("GET", 'conversations', nil, function(response, err)
		if err then
			log.error("Planner request failed: " .. err)
			callback(nil, err)
			return
		end

		if #response > 0 then
			M.conversation_id = response[1]["id"]
			log.debug("Found conversarion id: " .. M.conversation_id)
			return M.receive_prompt(prompt, callback)
		end

		log.debug("Creating new conversarion id")
		client.request("POST", 'conversations', {
			agent_id = M.id,
			inputs = prompt,
			handoff_execution = "server"
		}, function(response, err)
			if err then
				log.error("Planner request failed: " .. err)
				callback(nil, err)
				return
			end

			M.conversation_id = response["conversation_id"]
			log.debug("Created new conversarion id: " .. M.conversation_id)

			local outputs = response["outputs"]
			local content = outputs[#outputs]["content"]
			if not content then
				callback(nil)
				return
			end
			local res = content
			callback(vim.json.decode(res))
		end)
	end)
end

return M
