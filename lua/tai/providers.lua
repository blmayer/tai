local M = {}

local log = require("tai.log")
local common = require("tai.provider_common")
local config = require("tai.config")

-- Rate limiting variables
local request_tokens = {}  -- Queue of {timestamp, tokens_used} pairs (one entry per request attempt)
local pending_timers = {}

-- Helper function to clean old timestamps outside the 1-min window
local function cleanup_old_timestamps()
	local current_time = os.time()
	local window_seconds = 60
	while #request_tokens > 0 and (current_time - request_tokens[1][1] > window_seconds) do
		table.remove(request_tokens, 1)
	end
end

-- Simple, accurate estimator for the token cost of an outgoing request.
-- Instead of trying to walk only text content (which misses tool definitions,
-- tool calls, image data, full formatting, etc.), we serialize the *entire*
-- request body to JSON and use its length as the basis for the heuristic.
--
-- This correctly accounts for:
--   - Full message history (including huge tool results from "read")
--   - Tool definitions / schemas
--   - Image content (base64)
--   - Everything else that actually gets sent to the provider
--
-- Heuristic: most tokenizers for these models are ~4 chars per token.
-- Small additive buffer. The divisor/buffer is tuned so that the initial
-- planner system prompt + its tools JSON gives approximately 2230 tokens.
local function estimate_tokens_from_request_body(body)
	if not body then return 2500 end
	local ok, json_str = pcall(vim.json.encode, body)
	if not ok or type(json_str) ~= "string" then
		-- Very conservative fallback if encoding fails for some reason
		return 12000
	end
	local size = #json_str
	-- ~4 chars/token is a common rough heuristic for these models.
	-- Small buffer for safety. Tuned so that system prompt + tools gives ~2230.
	return math.max(1500, math.ceil(size / 4) + 50)
end


-- Simple 60s sliding window.
-- Caller is responsible for manually counting the cost of the request it wants
-- to make right now (using estimate + output headroom etc.).
-- We insert that cost (with current timestamp) only when we actually send.
-- Returns milliseconds to wait before this request can be sent (0 = go ahead).
local function get_wait_ms_for_next_request(cost)
	cleanup_old_timestamps()
	local now = os.time()
	local sum = 0
	for _, e in ipairs(request_tokens) do
		sum = sum + (e[2] or 0)
	end
	local wait_s = 0

	-- tpm: total tokens exchanged (our manual ctx+output costs) in last 60s < tpm
	if config.tpm and cost then
		if sum + cost >= config.tpm then
			local excess = sum + cost - config.tpm + 1
			local acc = 0
			for _, e in ipairs(request_tokens) do
				acc = acc + (e[2] or 0)
				if acc >= excess then
					wait_s = math.max(wait_s, (e[1] + 60 - now) + 1)
					break
				end
			end
		end
	end

	-- rpm: keep number of requests in the window under limit
	if config.rpm and #request_tokens >= config.rpm then
		local to_drop = #request_tokens - config.rpm + 1
		if to_drop > 0 and request_tokens[to_drop] then
			wait_s = math.max(wait_s, (request_tokens[to_drop][1] + 60 - now) + 1)
		end
	end

	if wait_s <= 0 then return 0 end
	return wait_s * 1000
end

-- Return current observed rate (sum of the costs we manually assigned).
function M.get_rate_limits()
	cleanup_old_timestamps()
	local total_tokens = 0
	local total_requests = #request_tokens
	for _, entry in ipairs(request_tokens) do
		total_tokens = total_tokens + (entry[2] or 0)
	end
	return {
		requests = total_requests,
		tokens = total_tokens,
	}
end

-- Check if there are pending throttle timers (requests waiting for rate limit).
function M.is_throttled()
	return #pending_timers > 0
end

-- Optional callback invoked when a request starts throttle-waiting.
-- Set by the UI layer to update state indicators.
M.on_throttle = nil

-- Cancel pending throttle timers.
function M.cancel_pending_waits()
	for _, timer in ipairs(pending_timers) do
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end
	pending_timers = {}
end

-- Small helper for response paths.
-- Record the *actual* cost returned by the provider (or the configured tpm on
-- rate-limit errors) for a request that was sent at `send_time`.
-- We only insert into the history when we have a real number from the provider
-- (the estimate is used *only* to decide whether we can send the request).
-- On rate errors we insert the full tpm value so the sliding window becomes
-- conservative and avoids immediate re-sends.
local function record_actual_cost(send_time, usage, err_msg)
	if usage and usage > 0 then
		table.insert(request_tokens, { send_time, usage })
		return
	end
	if err_msg and type(err_msg) == "string" then
		local lower = err_msg:lower()
		if lower:find("rate") or lower:find("429") or lower:find("too many") or lower:find("limit") then
			-- On rate limit error, conservatively record the full configured tpm
			-- as the cost for this request so the window prevents further sends soon.
			table.insert(request_tokens, { send_time, config.tpm or 10000 })
		end
	end
end

-- Provider configurations

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
	xai = {
		url = "https://api.x.ai/v1/chat/completions",
		api_key_env = "XAI_API_KEY",
		api_format = "chat_completions",
	},
	-- Generic/custom provider
	custom = {
		url = config.options.url,
		api_key_env = "",
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
		url = "http://localhost:11434/v1/chat/completions",
		api_key_env = "",
		api_format = "chat_completions",
	},
	llama_cpp = {
		url = "http://localhost:8080/v1/chat/completions",
		api_key_env = "",
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

	if provider_name == "openai_responses" then
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
			local function retry()
				M_module.request(model_config, msgs, callback)
			end

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

			-- Build the complete body first (Responses API uses "input" + tools etc.)
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

			-- Estimate from the full JSON payload (correctly sees tools, large inputs, etc.)
			local cost = estimate_tokens_from_request_body(body)

			local wait_ms = get_wait_ms_for_next_request(cost)
			if wait_ms > 0 then
				local timer = vim.uv.new_timer()
				table.insert(pending_timers, timer)
				if M.on_throttle then M.on_throttle(wait_ms) end
				timer:start(wait_ms, 0, function()
					for i = #pending_timers, 1, -1 do
						if pending_timers[i] == timer then table.remove(pending_timers, i) break end
					end
					timer:close()
					vim.schedule(retry)
				end)
				return
			end

			-- We decided we can send based on the estimate.
			-- Record the *actual* cost only when the response comes back.
			local send_time = os.time()

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
					record_actual_cost(send_time, nil, parsed.error.message)
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

				-- Record the actual cost returned by the provider (we only insert real values
				-- into the window; the estimate was used only for the send decision).
				local real = (parsed and parsed.usage and parsed.usage.total_tokens) or nil
				record_actual_cost(send_time, real, nil)
				callback(fields, nil)
			end)
		end

		-- Streaming request for OpenAI Responses API
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			local function retry()
				M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			end

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

			-- Build the complete body first
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

			-- Estimate from the full JSON (correctly captures everything sent)
			local cost = estimate_tokens_from_request_body(body)

			local wait_ms = get_wait_ms_for_next_request(cost)
			if wait_ms > 0 then
				local timer = vim.uv.new_timer()
				table.insert(pending_timers, timer)
				if M.on_throttle then M.on_throttle(wait_ms) end
				timer:start(wait_ms, 0, function()
					for i = #pending_timers, 1, -1 do
						if pending_timers[i] == timer then table.remove(pending_timers, i) break end
					end
					timer:close()
					vim.schedule(retry)
				end)
				return
			end

			-- We decided we can send based on the estimate.
			-- Record the *actual* cost only when the response comes back.
			local send_time = os.time()

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
					record_actual_cost(send_time, fields.token_usage, nil)
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

				-- Capture usage if the stream event includes it (for tpm tracking)
				if parsed.usage and parsed.usage.total_tokens then
					fields.token_usage = parsed.usage.total_tokens
				end
			end, function(err)
				if err then
					record_actual_cost(send_time, nil, err)
					on_complete(nil, err)
				end
				-- success path: [DONE] inside on_chunk already called on_complete
			end)
		end
	else
		-- Standard cloud provider logic
		local api_key = os.getenv(provider_config.api_key_env) or ""
		function M_module.request(model_config, msgs, callback)
	local function retry()
		M_module.request(model_config, msgs, callback)
	end

	-- Build the complete request body first (including tools, options, full messages, etc.)
	local body = {
		model = model_config.model,
		messages = common.filter_messages(msgs),
	}

	if config.use_tools ~= false then
		body.tools = common.build_request_tools(provider_config.api_format, model_config.tools)
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

	-- Now estimate cost from the *full* JSON that will actually be sent.
	-- This automatically includes tool definitions, images, formatting, etc.
	local cost = estimate_tokens_from_request_body(body)

	local wait_ms = get_wait_ms_for_next_request(cost)
	if wait_ms > 0 then
		local timer = vim.uv.new_timer()
		table.insert(pending_timers, timer)
		if M.on_throttle then M.on_throttle(wait_ms) end
		timer:start(wait_ms, 0, function()
			for i = #pending_timers, 1, -1 do
				if pending_timers[i] == timer then table.remove(pending_timers, i) break end
			end
			timer:close()
			vim.schedule(retry)
		end)
		return
	end

	-- We decided we can send based on the estimate.
	-- Record the *actual* cost only when the response comes back.
	local send_time = os.time()

	log.debug("[API] requesting " .. provider_config.url .. " with " .. vim.inspect(body))
	common.make_http_call(provider_config.url, api_key, request_body, function(parsed, err)
		if err then
			callback(nil, err)
			return
		end

		log.debug("[API] request response: " .. vim.inspect(parsed))

		if parsed.error then
			record_actual_cost(send_time, nil, parsed.error.message or "provider error")
			return callback(nil, parsed.error.message)
		end

		local real = (parsed and parsed.usage and parsed.usage.total_tokens) or nil
		record_actual_cost(send_time, real, err)
		local fields, _ = common.parse_response(parsed)
		callback(fields, err)
	end)
		end

		-- Streaming request
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
	local function retry()
		M_module.request_stream(model_config, msgs, on_chunk, on_complete)
	end

	-- Build the complete request body first
	local body = build_body(model_config, msgs)
	body.stream = true
	-- Ask for usage in the final stream chunk so our tpm counter sees real token counts
	body.stream_options = { include_usage = true }

	local request_body = vim.json.encode(body)

	-- Estimate from the *full* JSON payload (includes tools, images, formatting, etc.)
	local cost = estimate_tokens_from_request_body(body)

	local wait_ms = get_wait_ms_for_next_request(cost)
	if wait_ms > 0 then
		local timer = vim.uv.new_timer()
		table.insert(pending_timers, timer)
		if M.on_throttle then M.on_throttle(wait_ms) end
		timer:start(wait_ms, 0, function()
			for i = #pending_timers, 1, -1 do
				if pending_timers[i] == timer then table.remove(pending_timers, i) break end
			end
			timer:close()
			vim.schedule(retry)
		end)
		return
	end

	-- We decided we can send based on the estimate.
	-- Record the *actual* cost only when the response comes back.
	local send_time = os.time()

	log.debug("[API] requesting stream " .. provider_config.url .. " with " .. vim.inspect(body))

	local fields = {}

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
			record_actual_cost(send_time, nil, err)
			on_complete(nil, err)
			return
		end

		if fields.tool_calls then
			fields.tool_calls = common.merge_tool_calls(fields.tool_calls)
		end
		record_actual_cost(send_time, fields.token_usage, nil)
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

-- Exported only for testing the rate limiter estimator
M.estimate_tokens_from_request_body = estimate_tokens_from_request_body

return M
