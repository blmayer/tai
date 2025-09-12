-- init.lua: Initialize the agents package

local M = {}

local log = require('tai.log')
local library = require('tai.library')
local client = require('tai.agents.client')
local planner = require('tai.agents.planner')
local coder = require('tai.agents.coder')
local patcher = require('tai.agents.patcher')
local writer = require('tai.agents.writer')

-- Agent configurations
local agent_names = { "writer", "patcher", "coder", "planner" }

-- Function to list existing agents in Mistral
local function list_agents(callback)
	client.request("GET", 'agents', {}, function(response, err)
		if err then
			log.error("Failed to list agents: " .. err)
			callback(nil, err)
		else
			local existing_agents = {}
			for _, agent in ipairs(response) do
				existing_agents[agent.name] = agent.id
			end
			callback(existing_agents)
		end
	end)
end

-- Function to create an agent in Mistral if it does not exist
local function create_agent(name, callback)
	local handoffs = {
		writer = nil,
		patcher = { writer.id },
		coder = { patcher.id, writer.id },
		planner = { coder.id, patcher.id, writer.id }
	}

	local agent_configs = {
		writer = {
			name = "writer",
			model = "mistral-medium-latest",
			instructions = writer.system_prompt,
			handoffs = handoffs[name],
			tools = {
				{
					type = "document_library",
					library_ids = { library.id }
				}
			}
		},
		patcher = {
			name = "patcher",
			model = "mistral-medium-latest",
			instructions = patcher.system_prompt,
			handoffs = handoffs[name],
			tools = {
				{
					type = "document_library",
					library_ids = { library.id }
				}
			}
		},
		coder = {
			name = "coder",
			model = "mistral-large-latest",
			instructions = coder.system_prompt,
			handoffs = handoffs[name],
			tools = {
				{
					type = "document_library",
					library_ids = { library.id }
				}
			}
		},
		planner = {
			name = "planner",
			model = "magistral-medium-latest",
			instructions = planner.system_prompt,
			handoffs = handoffs[name],
			tools = {
				{
					type = "document_library",
					library_ids = { library.id }
				}
			}
		}
	}

	client.request("POST", 'agents', agent_configs[name], function(response, err)
		if err then
			log.error("Failed to create agent: " .. name .. " - " .. err)
			callback(nil, err)
			return
		end
		if response.id then
			log.info("Created agent " .. name)
			callback(response.id)
		end
	end)
end

local function await_create_agent(name)
	local co = coroutine.running()
	create_agent(name, function(result)
		coroutine.resume(co, result)
	end)
	return coroutine.yield()
end


local function set_agent_id(name, id)
	if name == "planner" then
		planner.id = id
	elseif name == "coder" then
		coder.id = id
	elseif name == "patcher" then
		patcher.id = id
	elseif name == "writer" then
		writer.id = id
	end

	log.info("Initialized agent: " .. name .. " with ID: " .. id)
end

-- Initialize library and agents
function M.init(callback)
	log.info("Initializing agents")
	if not library.id then
		callback("Failed to initialize agents: library id is empty")
		return
	end

	list_agents(function(agents, err)
		if err then
			log.error("Failed to initialize agents: " .. err)
			callback()
			return
		end

		coroutine.wrap(function()
			for _, agent_name in pairs(agent_names) do
				log.debug("Checking agent " .. agent_name)

				local found = false
				for name, id in pairs(agents) do
					if agent_name == name then
						found = true
						set_agent_id(name, id)
						log.debug("Found agent " .. name .. " ID " .. id)
					end
				end

				if not found then
					log.debug("Creating agent " .. agent_name)
					local id, err = await_create_agent(agent_name)
					if err then
						log.error("Failed to initialize agent: " .. agent_name)
						return
					end

					set_agent_id(agent_name, id)
				end
			end
		end)()

		callback()
	end)
end

return M
