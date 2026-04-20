local M = {}

local tools = require("tai.tools")
local log = require("tai.log")
local config = require("tai.config")

-- Filter a single message to remove internal fields
function M.filter_message(msg)
	local new_msg = {}
	for k, v in pairs(msg) do
		if k ~= "file_path" and k ~= "file_range" and k ~= "token_usage" then
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

-- Build tools for request, including provider tools
-- api_format: "responses" for OpenAI Responses API, "chat_completions" for Chat Completions API
function M.build_request_tools(api_format, tool_list)
	local request_tools = {}

	-- Add local tools based on API format
	if api_format == "responses" then
		-- OpenAI Responses API: tools need `name` at top level
		local function to_responses_tool(def)
			local t = vim.deepcopy(def)
			if t and t["function"] then
				t = t["function"]
				t.type = "function"
				t.strict = true
				t.additionalProperties = false
			end
			return t
		end

		for _, tool in ipairs(tool_list) do
			table.insert(request_tools, to_responses_tool(tools.defs[tool]))
		end
	else
		-- Chat Completions API: use standard tool format
		for _, tool in ipairs(tool_list) do
			table.insert(request_tools, tools.defs[tool])
		end
	end

	-- Add provider-side tools (e.g., web_search)
	if config.provider_tools then
		for _, tool in ipairs(config.provider_tools) do
			table.insert(request_tools, { type = tool })
		end
	end

	return request_tools
end

-- Streaming HTTP client using vim.uv process
-- Reads curl output line-by-line for true streaming support
function M.make_http_call(url, api_key, body_json, on_complete)
	local tmp = vim.fn.tempname()
	local ok_write, write_err = pcall(vim.fn.writefile, { body_json }, tmp)
	if not ok_write then
		return on_complete("Failed to write request body to temp file: " .. tostring(write_err))
	end

	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end

	local response = ""

	local job_id = vim.fn.jobstart({
		"curl",
		"-s",
		"-X", "POST", url,
		"-H", "Authorization: Bearer " .. api_key,
		"-H", "HTTP-Referer: https://terminal.pink/tai/index.html",
		"-H", "X-Title: tai.nvim",
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp,
	}, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				on_complete(nil, nil)
				return
			end
			log.debug("[API] received data: " .. vim.inspect(data))
				for _, line in ipairs(data) do
					response = response .. line
				end
		end,

		on_stderr = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						log.error("[API] curl error:" .. line)
					end
				end
			end
		end,

		on_exit = function(_, code)
			cleanup()
			if code ~= 0 then
				log.debug("[API] command returned code " .. tostring(code))
				on_complete("curl returned code " .. tostring(code))
				return
			end
			local parsed = vim.json.decode(response)
			if not parsed then
				on_complete(nil, "Failed to decode JSON response")
				return
			end
			on_complete(parsed, nil)
		end,
	})

	if job_id <= 0 then
		cleanup()
		on_complete("Failed to start job")
	end
end

-- Extract fields (content, tool_calls) from a standard OpenAI-style response
-- format is the requested format (e.g., "json_object")
function M.extract_fields(message)
	local fields = {}
	if not message then
		return nil, "No message in response"
	end

	if message.error then
		fields.error = message.error.message
	end

	local content = message.content
	if content and content ~= vim.NIL then
		fields.content = content
	else
		-- Some providers fail if you send them a message without content
		fields.content = ""
	end

	-- Extract reasoning details from response
	if message.reasoning or message.reasoning_content then
		local reasoning_text = message.reasoning or message.reasoning_content
		if reasoning_text and reasoning_text ~= "" and reasoning_text ~= vim.NIL then
			fields.reasoning = reasoning_text
		end
	end

	-- Some providers (e.g., MiniMax) return reasoning_details directly
	if message.reasoning_details and #message.reasoning_details > 0 then
		fields.reasoning = message.reasoning_details[1].text
	end

	if message.tool_calls and message.tool_calls ~= vim.NIL then
		fields.tool_calls = message.tool_calls
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

-- Streaming HTTP client using vim.uv process
-- Reads curl output line-by-line for true streaming support
function M.make_streaming_http_call(url, api_key, body_json, on_chunk, on_complete)
	local tmp = vim.fn.tempname()
	local ok_write, write_err = pcall(vim.fn.writefile, { body_json }, tmp)
	if not ok_write then
		return on_complete("Failed to write request body to temp file: " .. tostring(write_err))
	end

	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end

	local job_id = vim.fn.jobstart({
		"curl",
		"-s",
		"-N",
		"-X", "POST", url,
		"-H", "Authorization: Bearer " .. api_key,
		"-H", "HTTP-Referer: https://terminal.pink/tai/index.html",
		"-H", "X-Title: tai.nvim",
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp,
	}, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			if not data then return end
			log.debug("received data: " .. vim.inspect(data))

			for _, chunk in ipairs(data) do
				if chunk ~= "" then
					on_chunk(chunk)
				end
			end
		end,

		on_stderr = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						log.err("[API] curl error:", line)
					end
				end
			end
		end,

		on_exit = function(_, code)
			cleanup()
			if code ~= 0 then
				log.debug("[API] command returned code " .. tostring(code))
				on_complete("curl returned code " .. tostring(code))
				return
			end
			on_complete(nil)
		end,
	})

	if job_id <= 0 then
		cleanup()
		on_complete("Failed to start job")
	end
end

function M.parse_response(res)
	if #res.choices == 0 or not res.choices[1].message then
		return nil, "no choices received"
	end

	local fields, extract_err = M.extract_fields(res.choices[1].message)
	if extract_err then
		return nil, extract_err
	end
	if res.usage and res.usage.total_tokens then
		fields.token_usage = res.usage.total_tokens
	end

	return fields
end

function M.parse_chunk(chunk)
	local ok, decoded = pcall(vim.json.decode, chunk)
	if not ok then
		if chunk:sub(1, 6) ~= "data: " then
			log.debug("chunk is not data, ignoring: " .. chunk)
			return {}, nil
		end
		chunk = chunk:sub(7)
	end

	if chunk == "[DONE]" then
		return {}, nil
	end

	-- try again
	if not ok then
		ok, decoded = pcall(vim.json.decode, chunk)
		if not ok then
			return nil, "failed to decode JSON: " .. chunk
		end
	end
	log.debug("[API] parsed chunk: " .. vim.inspect(decoded))

	if decoded.error then
		return { error = decoded.error.message }
	end
	local message = decoded.choices[1].delta
	local fields, err = M.extract_fields(message)
	if err then
		return fields, err
	end
	if decoded.usage and decoded.usage.total_tokens then
		fields.token_usage = decoded.usage.total_tokens
	end

	return fields
end

function M.update_fields(fields, chunk)
	if chunk.error then
		fields.error = chunk.error
	end

	if chunk.content then
		fields.content = (fields.content or "") .. chunk.content
	end

	if chunk.reasoning then
		fields.reasoning = (fields.reasoning or "") .. chunk.reasoning
	end

	if chunk.tool_calls then
		if not fields.tool_calls then
			fields.tool_calls = {}
		end
		for _, call in ipairs(chunk.tool_calls) do
			log.debug("[API] updating tool call: " .. vim.inspect(call))

			local idx = call.index
			local fn = call["function"]
			local saved_call = fields.tool_calls[idx]

			if not saved_call then
				fields.tool_calls[idx] = call
				log.debug("[API] created new tool call")
			else
				fields.tool_calls[idx].name = saved_call["function"].name .. (fn.name or "")
				fields.tool_calls[idx]["function"].arguments = saved_call["function"].arguments ..
				    tostring(fn.arguments)
				log.debug("[API] updated tool call: " .. vim.inspect(fields.tool_calls[idx]))
			end
		end
	end

	if chunk.token_usage then
		fields.token_usage = (fields.token_usage or 0) + chunk.token_usage
	end
	return fields
end

function M.merge_tool_calls(calls)
	local new_calls = {}
	for _, call in pairs(calls) do
		if not call.id then
			call.id = "call_" .. tostring(vim.uv.hrtime())
		end
		table.insert(new_calls, call)
	end
	return new_calls
end

return M
