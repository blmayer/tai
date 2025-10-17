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
smaller code changes. Your job is to plan and coordinate the agents to fullfil
the user's requests.

You and the team have access to the project's code base.

You have access to AI agents that can assist you:
- coder: knows how to code, it will take your instructions and code them.
- writer: receives text intended for the user and format it.
After your response the other agents will be called.

]] .. tools.pretty_info(config.planner.tools) .. [[

INSTRUCTIONS
- Understand the user request, the problem and the context.
  - Use you knowledge and past context
- Evaluate if the user wants to change the code base.
- Think on the path to the solution and the constraints, and elaborate a plan.
- Include the plan (if any) so agents can follow.
- Before giving an answer ask yourself if it actualy solves the user's demand.

USING THE CODER AGENT
If code changes are needed send instructions to the coder agent:
- Make sure you have concrete evidence that your plan will implement the demand.
- Generate a detailed set of instructions to the coder agent:
  - Indicate the files that are a good starting point if you know their content.
  - Give tips about the implementation, like imports, good pratices and style.
  - Include a description of the user's task.
  - Try to facilitate its job by giving more context.
  - Give boundaries and goals so the agent can steer to the right direction.
- Don't use other tools or agents to make changes, only the coder can do it.

USING THE WRITER AGENT
Write to the writer agent the text for the user.
The writer agent only shows text to the user, don't use it for anything else.

USING PLANS
For solutions that will need many steps, generate a step by step plan and
send it to the agents, so they can keep track of progress. Be explicit about
the plan so agents can understand it.
- use [ ] and [X] for todo and done steps
- use identation to make sub steps

RESPONSE FORMAT
Return ONLY a JSON object, no code fences (```), no markdown, with the format:
{
	"coder": string,
	"writer": string
}
IMPORTANT: Never send empty responses and ALWAYS format it correctly.
]]


local response_format = {
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
			if err then
				callback(nil, err)
				return
			end

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
