local M = {}

local log = require("tai.log")
local tools = require("tai.tools")
local common = require("tai.provider_common")
local config = require("tai.config")

-- Provider configurations
-- Each provider has:
-- - url: The API endpoint URL (can be a function for dynamic URLs)
-- - api_key_env: Environment variable name for the API key (nil for no API key)
-- - api_format: "chat_completions" for standard API, "responses" for OpenAI Responses API
local providers_config = {
	mistral = {
		url = "https://api.mistral.ai/v1/chat/completions",
		api_key_env = "MISTRAL_API_KEY",
		api_format = "chat_completions",
	},
	gemini = {
		url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
		api_key_env = "GEMINI_API_KEY",
		api_format = "chat_completions",
	},
	groq = {
		url = "https://api.groq.com/openai/v1/chat/completions",
		api_key_env = "GROQ_API_KEY",
		api_format = "chat_completions",
	},
	openrouter = {
		url = "https://openrouter.ai/api/v1/chat/completions",
		api_key_env = "OPENROUTER_API_KEY",
		api_format = "chat_completions",
	},
	minimax = {
		url = "https://api.minimax.io/v1/chat/completions",
		api_key_env = "MINIMAX_API_KEY",
		api_format = "chat_completions",
	},
	stepfun = {
		url = "https://api.stepfun.ai/v1/chat/completions",
		api_key_env = "STEPFUN_API_KEY",
		api_format = "chat_completions",
	},
	z_ai = {
		url = "https://api.z.ai/api/paas/v4/chat/completions",
		api_key_env = "Z_AI_API_KEY",
		api_format = "chat_completions",
	},
	-- Generic/custom provider
	custom = {
		url = function() return config.options.url end,
		api_key_env = nil,
		api_format = "chat_completions",
	},
	-- OpenAI Responses API provider
	openai_responses = {
		url = "https://api.openai.com/v1/responses",
		api_key_env = "OPENAI_API_KEY",
		api_format = "responses",
	},
	-- Ollama/local provider
	ollama = {
		url = function() return config.options.ollama_url or 'http://localhost:11434/v1/chat/completions' end,
		api_key_env = nil,
		api_format = "chat_completions",
	},
}

-- Create a provider module for a specific provider
local function create_provider_module(provider_name)
	local provider_config = providers_config[provider_name]
	if not provider_config then
		error("Unknown provider: " .. tostring(provider_name))
	end

	local M_module = {}

	-- Build request body based on provider configuration
	local function build_body(model_config, msgs)
		-- Keep connected files up to date in history before sending
		tools.refresh_connected_files(msgs)

		local agent_tools = common.build_request_tools(provider_config.api_format, model_config.tools)

		local body = {
			model = model_config.model,
			messages = common.filter_messages(msgs),
		}

		if config.use_tools ~= false and #agent_tools > 0 then
			body.tools = agent_tools
		end

		if model_config.think ~= nil then
			body.reasoning_effort = model_config.think
		end

		if model_config.options then
			for k, v in pairs(model_config.options) do
				body[k] = v
			end
		end

		-- Special handling for JSON format
		return body
	end

	-- Provider-specific implementations
	if provider_name == "custom" then
		-- Generic provider using config.options.url
		local history = nil

		function M_module.add_to_history(message)
			local msg = vim.deepcopy(message)
			if not history then
				history = { msg }
				return
			end
			table.insert(history, msg)
		end

		function M_module.clear_history()
			history = nil
		end

		-- Non-streaming request
		function M_module.request(model_config, msgs, callback)
			for _, msg in ipairs(msgs) do
				M_module.add_to_history(msg)
			end

			-- Keep connected files up to date in history before sending
			tools.refresh_connected_files(history)

			local body = {
				model = model_config.model,
				messages = {},
			}

			if config.use_tools ~= false then
				body.tools = common.build_request_tools("chat_completions")
			end
			body.messages = common.filter_messages(history)

			if model_config.think ~= nil then
				body.reasoning_effort = model_config.think
			end

			if model_config.options then
				for k, v in pairs(model_config.options) do
					body[k] = v
				end
			end

			local request_body = vim.json.encode(body)

			log.debug("[API] requesting " .. provider_config.url() .. " with " .. vim.inspect(body))

			common.make_http_call(provider_config.url(), "", request_body, function(parsed, err)
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

		-- Streaming request
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			local body = build_body(model_config, msgs)
			body.stream = true

			log.debug("[API] requesting stream " .. provider_config.url() .. " with " .. vim.inspect(body))
			local request_body = vim.json.encode(body)

			local fields = {}

			common.make_streaming_http_call(provider_config.url(), "", request_body, function(chunk)
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
	elseif provider_name == "openai_responses" then
		-- OpenAI Responses API provider
		local history = nil
		local api_key = os.getenv("OPENAI_API_KEY")
		if not api_key then
			vim.schedule(function()
				vim.notify("[tai] ❌ Missing OPENAI_API_KEY environment variable.", vim.log.levels.ERROR)
			end)
		end

		local function add_history_message(message)
			if not history then
				history = {}
			end
			table.insert(history, vim.deepcopy(message))
		end

		local function to_responses_input(msg)
			log.debug(vim.inspect(msg))
			-- Map chat-style messages into Responses API "input" items.
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
						table.insert(res, {
							type = "function_call",
							name = call["function"].name,
							call_id = call.id,
							arguments = call["function"].arguments,
						})
					end
				end
				return res
			elseif msg.role == "tool" then
				return { {
					type = "function_call_output",
					output = msg.content or "",
					call_id = msg.tool_call_id
				} }
			end
		end

		function M_module.add_to_history(message)
			local msg = vim.deepcopy(message)
			for _, call in ipairs(msg.tool_calls or {}) do
				local args = call["function"].arguments
				if type(args) ~= "string" then
					call["function"].arguments = vim.json.encode(args)
				end
			end
			add_history_message(msg)
		end

		function M_module.clear_history()
			history = nil
		end

		function M_module.request(model_config, msgs, callback)
			for _, msg in ipairs(msgs) do
				add_history_message(vim.deepcopy(msg))
			end

			tools.refresh_connected_files(history)

			local input = {}
			for _, msg in ipairs(history or {}) do
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
				body.tools = common.build_request_tools("responses")
			end

			if model_config.options then
				for k, v in pairs(model_config.options) do
					body[k] = v
				end
			end

			local request_body = vim.json.encode(body)

			log.debug("Requesting " .. provider_config.url .. " with " .. vim.inspect(body))

			if not api_key then
				return callback(nil, "Missing OPENAI_API_KEY environment variable.")
			end

			common.make_http_call(provider_config.url, api_key, request_body, function(parsed, err)
				if err then
					callback(nil, err)
					return
				end

				log.debug("Request response: " .. vim.inspect(parsed))

				if parsed and parsed.error ~= vim.NIL then
					return callback(nil, "Received error: " .. parsed.error.message)
				end

				local fields = {}

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
					fields.content = output_text
				end

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
		end

		-- Streaming request for OpenAI Responses API
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			for _, msg in ipairs(msgs) do
				add_history_message(vim.deepcopy(msg))
			end

			local input = {}
			for _, msg in ipairs(history or {}) do
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
				stream = true,
			}

			if config.use_tools ~= false then
				body.tools = common.build_request_tools("responses")
			end

			if model_config.options then
				for k, v in pairs(model_config.options) do
					body[k] = v
				end
			end

			local request_body = vim.json.encode(body)

			log.debug("Streaming Requesting " .. provider_config.url)

			if not api_key then
				return on_complete(nil, "Missing OPENAI_API_KEY environment variable.")
			end

			local fields = {}

			common.make_streaming_http_call(provider_config.url, api_key, request_body, function(chunk)
				-- Handle data: prefix and [DONE] marker
				local data_prefix = "data: "
				local chunk_str = tostring(chunk)

				if chunk_str:sub(1, data_prefix:len()) == data_prefix then
					chunk_str = chunk_str:sub(data_prefix:len() + 1)
				end

				if chunk_str == "[DONE]" then
					if fields.tool_calls then
						fields.tool_calls = common.merge_tool_calls(fields.tool_calls)
					end
					on_complete(fields, nil)
					return
				end

				-- Parse the chunk
				local ok, parsed = pcall(vim.json.decode, chunk_str)
				if not ok then
					log.debug("Failed to parse chunk: " .. chunk_str)
					on_chunk(nil, "Failed to parse chunk")
					return
				end

				if parsed and parsed.error ~= vim.NIL then
					on_chunk(nil, "Received error: " .. parsed.error.message)
					return
				end

				-- Process output
				local output_text = ""
				if parsed.output and #parsed.output > 0 then
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

					if output_text and output_text ~= "" then
						on_chunk({ content = output_text }, nil)
						fields.content = (fields.content or "") .. output_text
					end
				end

				-- Process tool calls
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
								index = item.index or 0,
								["function"] = {
									name = item.name,
									arguments = args or {},
								},
							}

							if not fields.tool_calls then
								fields.tool_calls = {}
							end
							table.insert(fields.tool_calls, tool_call)
						end
					end
				end

				-- Process reasoning details
				if parsed.reasoning_details and #parsed.reasoning_details > 0 then
					if not fields.reasoning_details then
						fields.reasoning_details = {}
					end
					for _, reason in ipairs(parsed.reasoning_details) do
						table.insert(fields.reasoning_details, reason)
					end
				end
			end, function(err)
				if err then
					on_complete(nil, err)
				end
			end)
		end
	else
		-- Standard cloud provider logic
		local api_key = os.getenv(provider_config.api_key_env)
		if not api_key then
			vim.schedule(function()
				vim.notify("[tai] ❌ Missing " .. provider_config.api_key_env .. " environment variable.",
					vim.log.levels.ERROR)
			end)
		end

		-- Non-streaming request
		function M_module.request(model_config, msgs, callback)
			tools.refresh_connected_files(msgs)

			local body = {
				model = model_config.model,
				messages = {},
			}

			if config.use_tools ~= false then
				body.tools = common.build_request_tools(provider_config.api_format)
			end
			body.messages = common.filter_messages(msgs)

			if model_config.think ~= nil then
				body.reasoning_effort = model_config.think
			end

			if model_config.options then
				for k, v in pairs(model_config.options) do
					body[k] = v
				end
			end

			local request_body = vim.json.encode(body)

			log.debug("[API] requesting " .. provider_config.url .. " with " .. vim.inspect(body))

			if not api_key then
				return callback(nil,
					"Missing API key environment variable: " .. provider_config.api_key_env)
			end

			common.make_http_call(provider_config.url, api_key, request_body, function(parsed, err)
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

		-- Streaming request
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			local body = build_body(model_config, msgs)
			body.stream = true

			log.debug("[API] requesting stream " .. provider_config.url .. " with " .. vim.inspect(body))
			local request_body = vim.json.encode(body)

			local fields = {}

			local api_key = os.getenv(provider_config.api_key_env)
			if not api_key then
				vim.schedule(function()
					vim.notify(
						"[tai] ❌ Missing " ..
						provider_config.api_key_env .. " environment variable.",
						vim.log.levels.ERROR)
				end)
				on_complete(nil, "Missing API key environment variable: " .. provider_config.api_key_env)
				return
			end

			common.make_streaming_http_call(provider_config.url, api_key, request_body, function(chunk)
				local chunk_data, err = common.parse_chunk(chunk)
				if err then
					on_chunk(chunk_data, err)
					return
				end

				fields = common.update_fields(fields, chunk_data)

				on_chunk(chunk_data, nil)
			end, function(_, err)
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
	end

	return M_module
end

-- Get a provider module by name
-- @param provider_name string Name of the provider (e.g., "mistral", "gemini", etc.)
function M.get_provider(provider_name)
	return create_provider_module(provider_name)
end

return M
