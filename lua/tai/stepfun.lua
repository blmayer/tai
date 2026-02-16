local M = {}
local provider_common = require("tai.provider_common")
local tools = require("tai.tools")
local config = require("tai.config")
local log = require("tai.log")
local url = "https://api.stepfun.ai/v1/chat/completions"

local api_key = os.getenv("STEPFUN_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing STEPFUN_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = nil

function M.add_to_history(message)
	if not history then
		history = { message }
		return
	end
	table.insert(history, message)
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

	local agent_tools = provider_common.build_agent_tools(model_config)

	local body = {
		model = model_config.model,
		messages = provider_common.filter_messages(history),
	}

	if config.use_tools ~= false and #agent_tools > 0 then
		body.tools = agent_tools
	end

	if format == "json_object" then
		body.response_format = { type = "json_object" }
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	log.debug("Requesting " .. url .. " with " .. vim.inspect(body))
	local request_body = vim.json.encode(body)

	provider_common.make_http_call(url, api_key, request_body, false, function(parsed, err)
		if err then
			return callback(nil, err)
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed.object == "error" then
			return callback(nil, parsed.message or "Unknown StepFun API error")
		end

		local fields, extract_err = provider_common.extract_fields(parsed, format)
		if extract_err then
			return callback(nil, extract_err)
		end

		-- Extract token usage if available
		if parsed.usage and parsed.usage.total_tokens then
			fields.token_usage = parsed.usage.total_tokens
		end
		callback(fields, nil)
	end)
end

return M
