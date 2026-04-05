local M = {}

local log = require("tai.log")
local common = require("tai.provider_common")
local tools = require("tai.tools")
local config = require("tai.config")
local url = 'http://localhost:11434/v1/chat/completions'

local history = nil

function M.add_to_history(message)
	local msg = vim.deepcopy(message)
	if not history then
		history = { msg }
		return
	end
	table.insert(history, msg)
end

function M.clear_history()
	history = nil
end

local function build_body(model_config, msgs, format)
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end

	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(history)

	local agent_tools = common.build_request_tools("chat_completions")

	local body = {
		model = model_config.model,
		messages = common.filter_messages(history),
	}

	if config.use_tools ~= false and #agent_tools > 0 then
		body.tools = agent_tools
	end

	if format == "json_object" then
		body.response_format = { type = "json_object" }
	end

	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	return body
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
		body.tools = common.build_request_tools("chat_completions")
	end
	body.messages = common.filter_messages(history)

	if format == "json_object" then
		body.response_format = { type = "json_object" }
	end

	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	local request_body = vim.json.encode(body)

	log.debug("[API] requesting " .. url .. " with " .. vim.inspect(body))

	common.make_http_call(url, "", request_body, function(parsed, err)
		if err then
			callback(nil, err)
			return
		end

		log.debug("[API] request response: " .. vim.inspect(parsed))

		if parsed.error then
			return callback(nil, parsed.error.message)
		end

		local fields, err = common.parse_response(parsed, format)
		callback(fields, err)
	end)
end

-- Streaming request function
function M.request_stream(model_config, msgs, format, on_chunk, on_complete)
	local body = build_body(model_config, msgs, format)
	body.stream = true

	log.debug("[API] requesting stream " .. url .. " with " .. vim.inspect(body))
	local request_body = vim.json.encode(body)

	local fields = {}

	common.make_streaming_http_call(url, "", request_body, function(chunk)
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
