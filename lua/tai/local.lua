local M = {}

local log = require("tai.log")
local tools = require("tai.agents.tools")

local url = 'http://localhost:11434/api/chat'

function M.request(model_config, messages, format, callback)
	local agent_tools = vim.tbl_map(
		function(t)
			return tools.defs[t]
		end,
		model_config.tools or {}
	)
	local body = {
		model = model_config.model,
		messages = messages,
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

	log.debug("Requesting " .. url .. " with " .. request_body)
	vim.system(
		{
			'curl', '-s', '-X', "POST", url,
			'-H', 'Content-Type: application/json',
			'-d', request_body
		}, { text = true }, function(obj)
			if obj.code ~= 0 then
				local err_msg = "curl returned code " .. obj.code
				callback(nil, err_msg)
				return
			end

			log.debug("Request response: " .. obj.stdout)
			if not obj.stdout or obj.stdout == "" then
				return callback(nil, "Received empty response from Gemini")
			end

			local parsed = vim.json.decode(obj.stdout)
			if not parsed then
				return callback(nil, "Failed to decode JSON: " .. parsed)
			end

			if #parsed > 0 and parsed.error then
				return callback(nil, "Received error: " .. parsed.error)
			end

			if parsed.error then
				return callback(nil, parsed.error)
			end

			local content = parsed.message.content
			local fields = {}
			if content and content ~= "" then
				log.debug("response content: " .. content)
				if format ~= nil then
					log.debug("parsing JSON content")
					fields.content = vim.json.decode(content)
					if not fields.content then
						return callback(nil, "Failed to decode message")
					end
				else
					fields.content = content
				end
			end
			fields.tool_calls = parsed.message.tool_calls
			callback(fields, nil)
		end)
end

return M
