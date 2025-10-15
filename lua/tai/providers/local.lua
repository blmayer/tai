local M = {}

local config = require("tai.config")
local log = require("tai.log")
local json = vim.json
local uv = vim.uv
local tools = require("tai.tools")

local url = 'http://localhost:11434/api'

function M.request(model_config, messages, format, callback)
	local url = url .. "/chat"
	local tools = vim.tbl_map(
		function(t)
			return tools[t]
		end,
		model_config.tools or {}
	)
	local body = { 
		model = model_config.model,
		messages = messages,
		stream = false,
		tools = tools,
	}
	if format then
		body.response_format = format
	end
	if model_config.think ~= nil then
		body.think = model_config.think
	end
	if model_config.options then
		body.options = model_config.options
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. request_body)
	vim.system(
		{
		'curl', '-s', '-X', "POST", url,
		'-H', 'Content-Type: application/json',
		'-d', request_body
	}, { text = true }, function(obj)
		if obj.code ~= 0 then
			log.error("LLM request failed: " .. obj.stderr)
			callback(nil, "Request failed: " .. obj.stderr)
			return
		end

		log.debug("Request response: " .. obj.stdout)
		if not obj.stdout or obj.stdout == "" then
			return { error = "[tai] Received empty response from Gemini" }
		end

		local parsed = vim.json.decode(obj.stdout)
		if not parsed then
			return { error = "[tai] Failed to decode JSON: " .. parsed }
		end

		if #parsed > 0 and parsed[1].error then
			return { error = "[tai] Received error: " .. parsed[1].error.message }
			end

		if parsed.error then
			return { error = parsed.error }
		end

		local message = parsed.message.content
		local fields = {}
		if message and message ~= "" then
			log.debug("response content: " .. message)
			fields = vim.json.decode(message)
			if not fields then
				vim.notify("[tai] Failed to decode message: " .. message, vim.log.levels.ERROR)
				return { error = "[tai] Failed to decode message: " .. message }
			end
		end
		fields["tools"] = parsed.message.tool_calls
		callback(fields, nil)
	end)
end

return M

