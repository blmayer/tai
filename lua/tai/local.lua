local M = {}

local log = require("tai.log")
local provider_common = require("tai.provider_common")
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

function M.request(model_config, msgs, format, callback)
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end

	local agent_tools = provider_common.build_agent_tools(model_config)
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
	provider_common.make_http_call(url, "", request_body, function(parsed, err)
		if err then
			return callback(nil, err)
		end

		log.debug("Request response: " .. vim.inspect(parsed))

		if parsed.error then
			return callback(nil, "Received error: " .. parsed.error.message)
		end

		local fields, extract_err = provider_common.extract_fields(parsed, format)
		if extract_err then
			return callback(nil, extract_err)
		end
		callback(fields, nil)
	end)
end

-- Streaming request function
function M.request_stream(model_config, msgs, format, on_chunk, on_complete)
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end

	local agent_tools = provider_common.build_request_tools("chat_completions")

	local body = {
		model = model_config.model,
		messages = provider_common.filter_messages(history),
		stream = true,
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

	local tmp = vim.fn.tempname()
	local ok_write = pcall(vim.fn.writefile, { request_body }, tmp)
	if not ok_write then
		return on_complete(nil, "Failed to write request body")
	end

	local function cleanup()
		pcall(vim.fn.delete, tmp)
	end

	local accumulated_content = ""
	local tool_calls = {}
	local reasoning_details = {}

	local job_id = vim.fn.jobstart({
		"curl",
		"-s",
		"-N",
		"-X", "POST", url,
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp,
	}, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			if not data then return end

			for _, chunk in ipairs(data) do
				log.debug("got chunk " .. chunk)
				if chunk == "" then goto continue end

				if chunk:sub(1, 6) == "data: " then
					local chunk_data = chunk:sub(7)

					if chunk_data == "[DONE]" then
						local fields = {
							content = accumulated_content,
							tool_calls = #tool_calls > 0 and tool_calls or nil,
							reasoning_details = #reasoning_details > 0 and
							reasoning_details or nil,
						}

						cleanup()
						on_complete(fields, nil)
						return
					end

					local ok, decoded = pcall(vim.json.decode, chunk_data)
					if ok and decoded and decoded.choices and #decoded.choices > 0 then
						local message = decoded.choices[1].delta
						local content = message.content
						if content == vim.NIL then
							content = nil
						end
						on_chunk(
							{
								content = content,
								reasoning_details = message.reasoning_details
							},
						nil)

						if message and message.tool_calls then
							for _, call in ipairs(message.tool_calls) do
								table.insert(tool_calls, call)
							end
						end
					end
				end

				::continue::
			end
		end,

		on_stderr = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						print("stderr:", line)
					end
				end
			end
		end,

		on_exit = function(_, code)
			if code ~= 0 then
				cleanup()
				on_complete(nil, "curl returned code " .. tostring(code))
			end
		end,
	})

	if job_id <= 0 then
		cleanup()
		on_complete(nil, "Failed to start job")
	end
end

return M
