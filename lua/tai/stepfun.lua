
local M = {}

local log = require("tai.log")
local tools = require("tai.tools")
local config = require("tai.config")
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

	local agent_tools = vim.tbl_map(
		function(t)
			return tools.defs[t]
		end,
		model_config.tools or {}
	)
	local body = {
		model = model_config.model,
		messages = {},
	}
	for _, message in ipairs(history) do
		local new_message = {}
		for key, value in pairs(message) do
			if key ~= "file_path" and key ~= "file_range" then
				new_message[key] = value
			end
		end
		table.insert(body.messages, new_message)
	end

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
	-- Use a temporary file to avoid E2BIG (argument list too long) with curl
	local tmp = vim.fn.tempname()
	local ok_write, write_err = pcall(vim.fn.writefile, { request_body }, tmp)
	if not ok_write then
		return callback(nil, "Failed to write request body to temp file: " .. tostring(write_err))
	end

	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end

	local ok_system, system_err = pcall(vim.system, {
		"curl", "-s", "-X", "POST", url,
		"-H", "Authorization: Bearer " .. api_key,
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp,
	}, { text = true }, function(obj)
		cleanup()
		if obj.code ~= 0 then
			local err_msg = "curl returned code " .. obj.code
			callback(nil, err_msg)
			return
		end

		if not obj.stdout or obj.stdout == "" then
			return callback(nil, "Received empty response from StepFun")
		end

		local parsed = vim.json.decode(obj.stdout)
		if not parsed then
			return callback(nil, "Failed to decode JSON: " .. obj.stdout)
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed.object == "error" then
			return callback(nil, parsed.message or "Unknown StepFun API error")
		end

		if not parsed.choices or #parsed.choices == 0 then
			return callback(nil, "No choices received from StepFun")
		end

		local message = parsed.choices[1].message
		local content = message.content
		local fields = {}
		if content and content ~= "" then
			if format == "json_object" then
				fields.content = vim.json.decode(content)
				if not fields.content then
					return callback(nil, "Failed to decode message content as JSON")
				end
			else
				fields.content = content
			end
		end

		if message.tool_calls and message.tool_calls ~= vim.NIL then
			fields.tool_calls = message.tool_calls
			for _, call in ipairs(fields.tool_calls) do
				local args = call["function"].arguments
				call["function"].arguments = vim.json.decode(args)
			end
		end

		-- Extract token usage if available
		if parsed.usage and parsed.usage.total_tokens then
			fields.token_usage = parsed.usage.total_tokens
		end
		callback(fields, nil)
	end)

	if not ok_system then
		cleanup()
		return callback(nil, tostring(system_err))
	end
end

return M
