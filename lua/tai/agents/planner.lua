-- planner.lua: Planner agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')
local client = require('tai.agents.client')
local tools = require('tai.agents.tools')

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
SYSTEM
You are Planner Tai, an experienced software architect. You are coordinating a
team of agents on the current project. Users will inquire you with questions
about anything, specially about the project, they may ask for refactors or
smaller code changes. Your job is to plan and coordinate the team to fullfil
the user's requests.

You and the team have access to the project's code base.

You have access to AI agents that can assist you:
- coder: knows how to code, it will take your instructions and code them.
- writer: receives text intended for the user and format it.
After your response the other agents will be called.

]] .. tools.pretty_info(config.planner.tools) .. [[

INSTRUCTIONS
These are general guiding tips you should follow while working:
- Understand the user request, the problem and the context
- Examinate the code base if you need, use the tools you have access to help
- Think on the path to the solution and the constraints, and elaborate a plan
If code changes are needed:
- Generate a detailed set of instructions to the coder agent so that:
  - The agent can know what the user wants
  - You will facilitate its job by giving more context and pointing to files
- Don't use other tools or agents to make changes, only the coder can do it
In any case:
- Write to the writer agent the text for the user.

USING PLANS
For solutions that will need many steps, generate a step by step plan and
send it to the agents, so they can keep track of progress.

RESPONSE FORMAT
Return ONLY a JSON object, no code fences (```), no markdown, with the format:
{
	"coder": "instructions to the coder agent (optional)",
	"writer": "instructions or text to the writer agent (required)"
}
Note: don't add the field "coder" if unecessary.
]]

local response_format = {
	name = "planner response",
	type = "object",
	properties = {
		coder = {
			description = "Intructions for the coder agent",
		      	type = "string",
		},
		writer = {
			description = "Text for the writer agent",
			type = "string",
		},
	},
}

local history = { { role = "system", content = M.system_prompt } }

function M.plan(prompt, callback)
	log.info("Planner received prompt: " .. prompt)

	local msg = { role = "user", content = prompt }
	table.insert(history, msg)

	provider.request(
		config.planner,
		history,
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

function M.run_tools(tool_calls, callback)
	log.info("Planner running tooks")

	local out = tools.run(tool_calls)
	local msg = { role = "tool", content = out }
	table.insert(history, msg)

	provider.request(
		config.planner,
		history,
		"json",
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
