local M = {}

local log = require("tai.log")
local tools = require("tai.tools")

local url = "https://api.mistral.ai/v1/chat/completions"

local api_key = os.getenv("MISTRAL_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing MISTRAL_API_KEY environment variable.", vim.log.levels.ERROR)
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
			if key ~= "file_path" then
				new_message[key] = value
			end
		end
		table.insert(body.messages, new_message)
	end

	if #agent_tools > 0 then
		body.tools = agent_tools
	end

	-- Mistral API does not directly support 'format', 'reasoning_effort' or 'extra_body' at the top level
	-- in the same way Gemini does.
	-- If a specific format (e.g., JSON) is needed, it's usually via 'response_format'.
	-- For now, I'll omit these or adapt if user specifies.
	if format == "json_object" then -- Assuming 'json_object' as a possible format for Mistral
		body.response_format = { type = "json_object" }
	end

	-- Add other model options if provided in model_config.options, assuming they are valid Mistral API parameters
	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	log.debug("Requesting " .. url .. " with " .. vim.inspect(body))

	local request_body = vim.json.encode(body)
	vim.system(
		{
			"curl", "-s", "-X", "POST", url,
			"-H", "Authorization: Bearer " .. api_key,
			"-H", "Content-Type: application/json",
			"-d", request_body,
		}, { text = true }, function(obj)
			if obj.code ~= 0 then
				local err_msg = "curl returned code " .. obj.code
				callback(nil, err_msg)
				return
			end

			if not obj.stdout or obj.stdout == "" then
				return callback(nil, "Received empty response from Mistral")
			end

			local parsed = vim.json.decode(obj.stdout)
			if not parsed then
				return callback(nil, "Failed to decode JSON: " .. obj.stdout)
			end
			log.debug("Request response: " .. vim.inspect(parsed))

			-- Mistral errors are usually at the root level, e.g., parsed.error
			if parsed.object == "error" then
				return callback(nil, parsed.message or "Unknown Mistral API error")
			end

			if not parsed.choices or #parsed.choices == 0 then
				return callback(nil, "No choices received from Mistral")
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

			-- Mistral tool call arguments are already JSON objects, no need to decode
			callback(fields, nil)
		end)
end

return M
