local M = {}

local tools = require("tai.tools")

-- Build agent tools from model_config
function M.build_agent_tools(model_config)
	return tools.defs
end

-- Filter a single message to remove internal fields
function M.filter_message(msg)
	local new_msg = {}
	for k, v in pairs(msg) do
		if k ~= "file_path" and k ~= "file_range" then
			new_msg[k] = v
		end
	end
	return new_msg
end

-- Filter a list of messages
function M.filter_messages(messages)
	local filtered = {}
	for _, msg in ipairs(messages) do
		table.insert(filtered, M.filter_message(msg))
	end
	return filtered
end

-- Make HTTP request using curl. use_temp_file = true writes body to temp file first.
-- callback receives (parsed, error)
function M.make_http_call(url, api_key, body_json, callback)
	local tmp = vim.fn.tempname()
	local ok_write, write_err = pcall(vim.fn.writefile, { body_json }, tmp)
	if not ok_write then
		return callback(nil, "Failed to write request body to temp file: " .. tostring(write_err))
	end
	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end
	local ok_system, system_err = pcall(vim.system, {
		"curl", "-s", "-X", "POST", url,
		"-H", "Authorization: Bearer " .. api_key,
		"-H", "HTTP-Referer: https://terminal.pink/tai/index.html",
		"-H", "X-Title: tai.nvim",
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp,
	}, { text = true }, function(obj)
		cleanup()
		if obj.code ~= 0 then
			callback(nil, "curl returned code " .. obj.code)
			return
		end
		if not obj.stdout or obj.stdout == "" then
			callback(nil, "Received empty response")
			return
		end
		local parsed = vim.json.decode(obj.stdout)
		if not parsed then
			callback(nil, "Failed to decode JSON response")
			return
		end
		callback(parsed, nil)
	end)
	if not ok_system then
		cleanup()
		callback(nil, tostring(system_err))
	end
end

-- Extract fields (content, tool_calls) from a standard OpenAI-style response
-- format is the requested format (e.g., "json_object")
function M.extract_fields(parsed, format)
	local fields = {}
	if not parsed.choices or #parsed.choices == 0 then
		return nil, "No choices received"
	end
	local message = parsed.choices[1].message
	if not message then
		return nil, "No message in response"
	end

	local content = message.content
	if content and content ~= "" then
		if format ~= nil then
			local decoded = vim.json.decode(content)
			if not decoded then
				return nil, "Failed to decode message content as JSON"
			end
			fields.content = decoded
		else
			fields.content = content
		end
	else
		-- Some providers fail if you send them a message without content
		fields.content = ""
	end

	-- Extract reasoning details from response
	if message.reasoning or message.reasoning_content then
		local reasoning_text = message.reasoning or message.reasoning_content
		if reasoning_text and reasoning_text ~= "" then
			fields.reasoning_details = { { text = reasoning_text } }
		end

		-- Some providers offer a more detailed reasoning response
		if message.reasoning_details then
			fields.reasoning_details = message.reasoning_details
		end

	end

	if message.tool_calls and message.tool_calls ~= vim.NIL then
		fields.tool_calls = message.tool_calls
		for _, call in ipairs(fields.tool_calls) do
			local args = call["function"].arguments
			if type(args) == "string" then
				local decoded = vim.json.decode(args)
				if decoded then
					call["function"].arguments = decoded
				end
			end
		end
	end

	-- Extract token usage if available
	if parsed.usage and parsed.usage.total_tokens then
		fields.token_usage = parsed.usage.total_tokens
	end

	return fields, nil
end

-- Decode tool call arguments if they are JSON strings
function M.decode_tool_call_arguments(calls)
	if not calls then return end
	for _, call in ipairs(calls) do
		local args = call["function"].arguments
		if type(args) == "string" then
			local decoded = vim.json.decode(args)
			if decoded then
				call["function"].arguments = decoded
			end
		end
	end
end

return M
