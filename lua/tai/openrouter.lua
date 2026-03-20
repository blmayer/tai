local M = {}

local tools = require("tai.tools")
local provider_common = require("tai.provider_common")
local config = require("tai.config")
local log = require("tai.log")
local url = "https://openrouter.ai/api/v1/chat/completions"

local api_key = os.getenv("OPENROUTER_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing OPENROUTER_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = nil

function M.add_to_history(message)
	local msg = vim.deepcopy(message)
	for _, call in ipairs(msg.tool_calls or {}) do
		local args = call["function"].arguments
		call["function"].arguments = vim.json.encode(args)
	end
	if not history then
		history = { msg }
		return
	end
	table.insert(history, msg)
end

function M.clear_history()
	history = nil
end

function M.request(model_config, msgs, format, callback)
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end

	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(history)

	local body = {
		model = model_config.model,
		messages = {},
	}

	if config.use_tools ~= false then
		body.tools = provider_common.build_request_tools("chat_completions")
	end
	body.messages = provider_common.filter_messages(history)

	if format == "json_object" then
		body.response_format = { type = "json_object" }
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end
	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end


	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. vim.inspect(body))

	provider_common.make_http_call(url, api_key, request_body, function(parsed, err)
		if err then
			callback(nil, err)
			return
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed.error then
			local error = parsed.error
			local msg = error.message
			if error.metadata and error.metadata.raw then
				msg = msg .. ": " .. error.metadata.raw
			end
			return callback(nil, msg)
		end

		local fields, extract_err = provider_common.extract_fields(parsed, format)
		if extract_err then
			return callback(nil, extract_err)
		end

		callback(fields, nil)
	end)
end

return M
