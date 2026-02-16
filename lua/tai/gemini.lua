local M = {}

local log = require("tai.log")
local provider_common = require("tai.provider_common")
local tools = require("tai.tools")
local config = require("tai.config")
local url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

local api_key = os.getenv("GEMINI_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing GEMINI_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = { {} }

function M.add_to_history(message)
	local msg = vim.deepcopy(message)
	for _, call in ipairs(msg.tool_calls or {}) do
		local args = call["function"].arguments
		call["function"].arguments = vim.json.encode(args)
	end
	table.insert(history, msg)
end

function M.clear_history()
	history = { {} }
end

function M.request(model_config, msgs, format, callback)
	-- Add messages to history
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end
	tools.refresh_connected_files(history)

	local body = {
		model = model_config.model,
		messages = history,
	}

	if config.use_tools ~= false then
		local agent_tools = provider_common.build_agent_tools(model_config)
		body.tools = agent_tools
	end

	if format then
		body.response_format = { type = format }
	end
	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end
	if model_config.options then
		body.extra_body = model_config.options
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. request_body)
	provider_common.make_http_call(url, api_key, request_body, false, function(parsed, err)
		if err then
			return callback(nil, err)
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		-- Gemini can return errors as array
		if #parsed > 0 and parsed[1].error then
			return callback(nil, "Received error: " .. parsed[1].error.message)
		end
		if parsed.error then
			return callback(nil, parsed.error)
		end

		if not parsed.choices or #parsed.choices == 0 then
			return callback(nil, "No choices received from Gemini")
		end

		local message = parsed.choices[1].message
		local fields = {}

		if message.content and message.content ~= "" then
			if format ~= nil then
				local decoded = vim.json.decode(message.content)
				if not decoded then
					return callback(nil, "Failed to decode message")
				end
				fields.content = decoded
			else
				fields.content = message.content
			end
		end

		fields.tool_calls = message.tool_calls
		provider_common.decode_tool_call_arguments(fields.tool_calls)

		callback(fields, nil)
	end)
end

return M
