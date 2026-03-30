local M = {}

local log = require("tai.log")
local common = require("tai.provider_common")
local tools = require("tai.tools")
local config = require("tai.config")
local url = 'http://localhost:11434/v1/chat/completions'

local history = nil

function M.add_to_history(message)
	log.debug("adding message to history")
	local msg = vim.deepcopy(message)
	for _, call in ipairs(msg.tool_calls or {}) do
		local args = call["function"].arguments
		call["function"].arguments = vim.json.encode(args)
	end

	if not history then
		log.debug("new history")
		history = { msg }
		return
	end
	log.debug("insert into history")
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

	local agent_tools = common.build_agent_tools(model_config)
	local body = {
		model = model_config.model,
		messages = history,
		stream = false,
		tools = agent_tools,
	}
	if format then
		body.format = format
	end
	if model_config.think ~= nil then
		body.think = model_config.think
	end
	if model_config.options then
		body.options = model_config.options
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. vim.inspect(body))
	common.make_http_call(url, "", request_body, function(parsed, err)
		if err then
			return callback(nil, err)
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed.error then
			return callback(nil, "Received error: " .. parsed.error.message)
		end

		local fields, extract_err = common.extract_fields(parsed, format)
		if extract_err then
			return callback(nil, extract_err)
		end
		callback(fields, nil)
	end)
end

-- Streaming request function
function M.request_stream(model_config, msgs, format, on_chunk, on_complete)
	local body = build_body(model_config, msgs, format)
	body.stream = true

	log.debug("Requesting stream " .. url .. " with " .. vim.inspect(body))
	local request_body = vim.json.encode(body)

	local fields = {
		content = "",
		tool_calls = {},
		reasoning_details = { { text = "" } },
	}

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
		fields.tool_calls = common.merge_tool_calls(fields.tool_calls)
		on_complete(fields, nil)
	end)
end

return M
