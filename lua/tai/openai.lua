local M = {}

local log = require("tai.log")
local tools = require("tai.tools")
local config = require("tai.config")

local responses_url = "https://api.openai.com/v1/responses"

local api_key = os.getenv("OPENAI_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing OPENAI_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = nil

local function add_history_message(message)
	if not history then
		history = {}
	end
	table.insert(history, vim.deepcopy(message))
end

local function to_responses_input(msg)
	log.debug(vim.inspect(msg))
	-- Map chat-style messages into Responses API "input" items.
	-- For tool messages, keep the tool_call_id.
	if msg.role == "user" or msg.role == "system" or msg.role == "developer" then
		return { {
			role = msg.role,
			content = {
				{ type = "input_text", text = msg.content or "" },
			},
		} }
	elseif msg.role == "assistant" then
		local res = { {
			role = "assistant",
			content = {
				{ type = "output_text", text = msg.content or "" },
			},
		} }

		if msg.tool_calls then
			for _, call in ipairs(msg.tool_calls) do
				table.insert(res,
					{
						type = "function_call",
						name = call["function"].name,
						call_id = call.id,
						arguments = call["function"].arguments,
					}
				)
			end
		end
		return res
	elseif msg.role == "tool" then
		return { {
			type = "function_call_output", output = msg.content or "", call_id = msg.tool_call_id
		} }
	end
end

function M.add_to_history(message)
	-- For Chat Completions tool_calls, arguments must be JSON strings.
	local msg = vim.deepcopy(message)
	for _, call in ipairs(msg.tool_calls or {}) do
		local args = call["function"].arguments
		if type(args) ~= "string" then
			call["function"].arguments = vim.json.encode(args)
		end
	end
	add_history_message(msg)
end

function M.clear_history()
	history = nil
end

function M.request(model_config, msgs, format, callback)
	-- Preserve existing chat history behavior but translate to Responses API.
	for _, msg in ipairs(msgs) do
		add_history_message(vim.deepcopy(msg))
	end

	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(history)

	local input = {}
	for _, msg in ipairs(history or {}) do
		-- strip file_path (internal)
		local new_msg = {}
		for k, v in pairs(msg) do
			if k ~= "file_path" and k ~= "file_range" then
				new_msg[k] = v
			end
		end
		local inputs = to_responses_input(new_msg)
		for _, inp in ipairs(inputs) do
			table.insert(input, inp)
		end
	end

	local body = {
		model = model_config.model,
		input = input,
		store = false,
	}

	if config.use_tools ~= false then
		-- Responses API expects tools to include a top-level `name`.
		-- Reuse our Chat Completions tool defs but add `name`.
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

		body.tools = {
			to_responses_tool(tools.defs["read_file"]),
			to_responses_tool(tools.defs["shell"]),
			to_responses_tool(tools.defs["patch"]),
			to_responses_tool(tools.defs["summarize"]),
			to_responses_tool(tools.defs["send_image"]),
		}

		if config.provider_tools then
			for _, tool in ipairs(config.provider_tools) do
				table.insert(body.tools, { type = tool })
			end
		end
	end

	-- Best-effort: only enable strict JSON output if format was requested.
	-- (This plugin historically uses `format` as a flag that content is JSON.)
	if format ~= nil then
		body.text = { format = { type = "json_object" } }
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. responses_url .. " with " .. vim.inspect(body))

	-- Avoid E2BIG (argument list too long) by writing the request body to a temp
	-- file instead of passing it as a curl argv element.
	local tmp = vim.fn.tempname()
	local ok_write, write_err = pcall(vim.fn.writefile, { request_body }, tmp)
	if not ok_write then
		return callback(nil, "Failed to write request body to temp file: " .. tostring(write_err))
	end

	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end

	local ok_system, system_err = pcall(vim.system, {
		"curl", "-s", "-X", "POST", responses_url,
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
			return callback(nil, "Received empty response from OpenAI")
		end

		local parsed = vim.json.decode(obj.stdout)
		if not parsed then
			return callback(nil, "Failed to decode JSON response")
		end
		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed and parsed.error ~= vim.NIL then
			return callback(nil, "Received error: " .. parsed.error.message)
		end

		local fields = {}

		-- Extract final output text.
		local output_text = parsed.output_text
		if (not output_text or output_text == vim.NIL) and parsed.output then
			local chunks = {}
			for _, item in ipairs(parsed.output) do
				if item and item.content then
					for _, c in ipairs(item.content) do
						if c.type == "output_text" and c.text then
							table.insert(chunks, c.text)
						end
					end
				end
			end
			output_text = table.concat(chunks, "")
		end

		if output_text and output_text ~= vim.NIL then
			if format ~= nil then
				fields.content = vim.json.decode(output_text)
				if not fields.content then
					return callback(nil, "Failed to decode message")
				end
			else
				fields.content = output_text
			end
		end

		-- Extract tool calls (function calls) from output.
		fields.tool_calls = {}
		if parsed.output then
			for _, item in ipairs(parsed.output) do
				if item and (item.type == "function_call" or item.type == "tool_call") then
					local args = item.arguments
					if type(args) == "string" then
						local decoded = vim.json.decode(args)
						if decoded then
							args = decoded
						end
					end

					local tool_call = {
						id = item.call_id,
						type = "function",
						["function"] = {
							name = item.name,
							arguments = args or {},
						},
					}
					table.insert(fields.tool_calls, tool_call)
				end
			end
		end

		callback(fields, nil)
	end)

	if not ok_system then
		cleanup()
		return callback(nil, tostring(system_err))
	end
end

return M
