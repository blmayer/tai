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

-- Rough token estimator for provisional cost of an outgoing request (based on the
-- messages being sent). This lets us count the "ongoing" request in the tpm window
-- immediately at dispatch time. We correct it with the real usage when the response
-- arrives.
local function estimate_tokens_from_messages(msgs)
	if not msgs then return 1500 end
	local chars = 0
	for _, msg in ipairs(msgs) do
		local c = msg.content
		if type(c) == "string" then
			chars = chars + #c
		elseif type(c) == "table" then
			for _, part in ipairs(c) do
				if type(part) == "table" and part.text then
					chars = chars + #part.text
				elseif type(part) == "string" then
					chars = chars + #part
				end
			end
		end
	end
	-- Over-estimate (smaller divisor + headroom) + fixed overhead for tool schemas
	-- (which are sent on every call when use_tools) to be safer against 429s on
	-- large contexts (e.g. "read" injecting big file for the next call).
	-- The provisional is used in the tpm decision *for this call itself*.
	-- Real usage from provider corrects the entry.
	local prompt_est = math.ceil(chars / 3) + 1200
	local tools_overhead = (config.use_tools ~= false) and 2500 or 0
	return math.max(2000, prompt_est + tools_overhead)
end

-- When we have a response (success or error) for a dispatched call, commit the
-- real usage if known, or on rate-limit errors bump the recorded cost so that
-- subsequent decisions are more conservative (we under-estimated or the provider
-- was stricter than our client tpm).
local function commit_call_cost(entry, usage, err_msg)
	if not entry then return end
	if usage and usage > 0 then
		entry[2] = usage
		return
	end
	if err_msg and type(err_msg) == "string" then
		local lower = err_msg:lower()
		if lower:find("rate") or lower:find("429") or lower:find("too many") or lower:find("limit") then
			entry[2] = math.max(entry[2] or 0, 10000)
		end
	end
end

-- Compute how many ms we need to wait (if any) before the next request can be sent
-- without exceeding rpm or the given max_tokens (tpm). Returns 0 if safe now.
-- additional_cost: provisional estimate for the call we're *about to* make (so we
-- account for the ongoing request's own tokens in this decision).
local function get_required_wait_ms(max_tokens, additional_cost)
	cleanup_old_timestamps()
	local total_tokens = 0
	local total_requests = #request_tokens
	for _, entry in ipairs(request_tokens) do
		total_tokens = total_tokens + (entry[2] or 0)
	end
	if additional_cost then
		total_tokens = total_tokens + additional_cost
	end
	local now = os.time()
	local wait_s = 0

	if config.rpm and total_requests >= config.rpm then
		local to_drop = total_requests - config.rpm + 1
		if to_drop > 0 and request_tokens[to_drop] then
			wait_s = math.max(wait_s, (request_tokens[to_drop][1] + 60 - now) + 1)
		end
	end

	if max_tokens and total_tokens >= max_tokens then
		local excess = total_tokens - max_tokens + 1
		local acc = 0
		for _, entry in ipairs(request_tokens) do
			acc = acc + (entry[2] or 0)
			if acc >= excess then
				wait_s = math.max(wait_s, (entry[1] + 60 - now) + 1)
				break
			end
		end
	end

	if wait_s <= 0 then return 0 end
	return math.max(0, math.ceil(wait_s * 1000))
end

-- Check limits and record attempt *only if safe right now*.
-- On success returns the specific rate entry table for this request (so its response
-- handler can precisely fill in the token count, even if responses arrive out-of-order).
-- Returns nil, err if a limit is hit.
local function check_and_record_request(max_tokens, initial_tokens)
	cleanup_old_timestamps()
	local total_tokens = 0
	local total_requests = #request_tokens
	for _, entry in ipairs(request_tokens) do
		total_tokens = total_tokens + (entry[2] or 0)
	end
	if initial_tokens then
		total_tokens = total_tokens + initial_tokens
	end
	if config.rpm and total_requests >= config.rpm then
		return nil, "Rate limit exceeded: " .. config.rpm .. " requests per minute allowed"
	end
	if max_tokens and total_tokens >= max_tokens then
		return nil, "Token rate limit exceeded: " .. max_tokens .. " tokens per minute allowed"
	end
	local entry = { os.time(), initial_tokens or 0 }
	table.insert(request_tokens, entry)
	return entry
end

-- Return current observed rate in the sliding window (after cleanup).
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

-- Cancel any pending auto-throttle timers (e.g. on user stop).
function M.cancel_pending_waits()
	for _, timer in ipairs(pending_timers) do
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end
	pending_timers = {}
end

-- Helper: if we must wait for the rate window, schedule a re-dispatch via timer and return false.
-- Otherwise record the attempt and return true (caller may then proceed).
-- retry_fn is a 0-arg function that will re-invoke the original request with captured args.
local function ensure_rate_limit_or_wait(max_tokens, retry_fn, initial_tokens)
	local wait_ms = get_required_wait_ms(max_tokens, initial_tokens)
	if wait_ms > 0 then
		local timer = vim.uv.new_timer()
		table.insert(pending_timers, timer)
		timer:start(wait_ms, 0, function()
			-- remove this timer from the list
			for i = #pending_timers, 1, -1 do
				if pending_timers[i] == timer then
					table.remove(pending_timers, i)
					break
				end
			end
			timer:close()
			-- The timer callback is a "fast event" context. vim.fn.* (tempname, writefile, jobstart etc.)
			-- are not allowed directly here. Schedule the actual request resume so it runs in a
			-- normal main-loop context (same as how send_input already wraps user sends).
			vim.schedule(retry_fn)
		end)
		return nil
	end

	-- Safe: record and proceed. Return the per-request entry so the response
	-- handler can update *this* entry's token count (no more blind "last" updates).
	-- initial_tokens (provisional estimate from the messages) is passed so the cost
	-- of this ongoing request is counted in the tpm window right at dispatch.
	local entry, err = check_and_record_request(max_tokens, initial_tokens)
	if not entry then
		return nil, err
	end
	return entry
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
			-- Estimate cost of this request so the ongoing request's tokens are
			-- counted in tpm immediately (real usage will correct the entry later).
			local provisional = estimate_tokens_from_messages(msgs)
			-- Add conservative output headroom (we pay for completion tokens too).
			-- Use max_tokens from options if present (capped for safety).
			do
				local max_out = 2048
				if model_config and model_config.options and type(model_config.options.max_tokens) == "number" then
					max_out = math.min(model_config.options.max_tokens, 4096)
				end
				provisional = provisional + max_out
			end
			local entry, err = ensure_rate_limit_or_wait(config.tpm, retry, provisional)
			if not entry then
				if err then callback(nil, err) end
				return
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
					commit_call_cost(entry, nil, parsed.error.message)
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

				-- Best-effort token usage for tpm tracking (Responses API) - precise to this request's entry
				local u = (parsed and parsed.usage and parsed.usage.total_tokens) or nil
				commit_call_cost(entry, u, nil)
				callback(fields, nil)
			end)
		end

		-- Streaming request for OpenAI Responses API
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			local function retry()
				M_module.request_stream(model_config, msgs, on_chunk, on_complete)
			end
			-- Estimate cost of this request so the ongoing request's tokens are
			-- counted in tpm immediately (real usage will correct the entry later).
			local provisional = estimate_tokens_from_messages(msgs)
			-- Add conservative output headroom (we pay for completion tokens too).
			-- Use max_tokens from options if present (capped for safety).
			do
				local max_out = 2048
				if model_config and model_config.options and type(model_config.options.max_tokens) == "number" then
					max_out = math.min(model_config.options.max_tokens, 4096)
				end
				provisional = provisional + max_out
			end
			local entry, err = ensure_rate_limit_or_wait(config.tpm, retry, provisional)
			if not entry then
				if err then on_complete(nil, err) end
				return
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
					-- precise per-request entry (Responses stream may report usage in final events)
					commit_call_cost(entry, fields.token_usage, nil)
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
					commit_call_cost(entry, nil, err)
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
	-- Estimate cost of this request (including full context being sent) so the
	-- ongoing request's tokens are counted in tpm immediately.
	local provisional = estimate_tokens_from_messages(msgs)
	-- Add conservative output headroom (we pay for completion tokens too).
	-- Use max_tokens from options if present (capped for safety).
	do
		local max_out = 2048
		if model_config and model_config.options and type(model_config.options.max_tokens) == "number" then
			max_out = math.min(model_config.options.max_tokens, 4096)
		end
		provisional = provisional + max_out
	end
	local entry, err = ensure_rate_limit_or_wait(config.tpm, retry, provisional)
	if not entry then
		if err then callback(nil, err) end
		return
	end

		local body = {
            model = model_config.model,
            messages = {},
        }

        if config.use_tools ~= false then
            body.tools = common.build_request_tools(provider_config.api_format, model_config.tools)
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
        common.make_http_call(provider_config.url, api_key, request_body, function(parsed, err)
            if err then
                callback(nil, err)
                return
            end

            log.debug("[API] request response: " .. vim.inspect(parsed))

            if parsed.error then
                commit_call_cost(entry, nil, parsed.error.message or "provider error")
                return callback(nil, parsed.error.message)
            end

            local fields, err = common.parse_response(parsed)
            -- Update *this* request's rate entry with actual tokens (precise, not "last")
            local usage = parsed and parsed.usage and parsed.usage.total_tokens or nil
            commit_call_cost(entry, usage, err)
            callback(fields, err)
        end)
		end

		-- Streaming request
		function M_module.request_stream(model_config, msgs, on_chunk, on_complete)
	local function retry()
		M_module.request_stream(model_config, msgs, on_chunk, on_complete)
	end
	-- Estimate cost of this request (including full context being sent) so the
	-- ongoing request's tokens are counted in tpm immediately.
	local provisional = estimate_tokens_from_messages(msgs)
	-- Add conservative output headroom (we pay for completion tokens too).
	-- Use max_tokens from options if present (capped for safety).
	do
		local max_out = 2048
		if model_config and model_config.options and type(model_config.options.max_tokens) == "number" then
			max_out = math.min(model_config.options.max_tokens, 4096)
		end
		provisional = provisional + max_out
	end
	local entry, err = ensure_rate_limit_or_wait(config.tpm, retry, provisional)
	if not entry then
		if err then on_complete(nil, err) end
		return
	end

		local body = build_body(model_config, msgs)
        body.stream = true
        -- Ask for usage in the final stream chunk so our tpm counter sees real token counts
        -- (many OpenAI-compatible providers, including Mistral, require/include this).
        body.stream_options = { include_usage = true }

        log.debug("[API] requesting stream " .. provider_config.url .. " with " .. vim.inspect(body))
        local request_body = vim.json.encode(body)

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
                commit_call_cost(entry, nil, err)
                on_complete(nil, err)
                return
            end

            if fields.tool_calls then
                fields.tool_calls = common.merge_tool_calls(fields.tool_calls)
            end
            -- Update *this* request's rate entry with actual tokens (precise ownership)
            commit_call_cost(entry, fields.token_usage, nil)
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
