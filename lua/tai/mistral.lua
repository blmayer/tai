local M = {}

local tools = require("tai.tools")
local common = require("tai.provider_common")
local config = require("tai.config")
local log = require("tai.log")
local url = "https://api.mistral.ai/v1/chat/completions"

local api_key = os.getenv("MISTRAL_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing MISTRAL_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local function build_body(model_config, msgs)
	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(msgs)

	local agent_tools = common.build_request_tools("chat_completions", model_config.tools)

	local body = {
		model = model_config.model,
		messages = common.filter_messages(msgs),
	}

	if config.use_tools ~= false and #agent_tools > 0 then
		body.tools = agent_tools
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	return body
end

function M.request(model_config, msgs, callback)
	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(msgs)

	local body = build_body(model_config, msgs)

	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end

	local request_body = vim.json.encode(body)

	log.debug("[API] requesting " .. url .. " with " .. vim.inspect(body))

	common.make_http_call(url, api_key, request_body, function(parsed, err)
		if err then
			callback(nil, err)
			return
		end

		log.debug("[API] request response: " .. vim.inspect(parsed))

		if parsed.error then
			return callback(nil, parsed.error.message)
		end

		local fields, err = common.parse_response(parsed)
		callback(fields, err)
	end)
end

-- Streaming request function
function M.request_stream(model_config, msgs, on_chunk, on_complete)
	local body = build_body(model_config, msgs)
	body.stream = true

	log.debug("[API] requesting stream " .. url .. " with " .. vim.inspect(body))
	local request_body = vim.json.encode(body)

	local fields = {}

	common.make_streaming_http_call(url, api_key, request_body, function(chunk)
		local chunk_data, err = common.parse_chunk(chunk)
		if err then
			on_chunk(chunk_data, err)
			return
		end

		-- accumulate
		fields = common.update_fields(fields, chunk_data)

		on_chunk(chunk_data, nil)
	end, function(_, err)
		-- on_complete: flatten tool_calls map to array and decode arguments
		if err then
			on_complete(nil, err)
			return
		end

		if fields.tool_calls then
			fields.tool_calls = common.merge_tool_calls(fields.tool_calls)
		end
		on_complete(fields, nil)
	end)
end

return M

