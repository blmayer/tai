local M = {}

local config = require("tai.config")
local log = require("tai.log")
local json = vim.json
local uv = vim.uv

local url = 'http://localhost:11434/api'

local read_tool = {
    type = "function",
    ["function"] = {
      name = "read_file",
      description = "Reads the content of a file from the file system.",
      parameters = {
        type = "object",
        properties = {
          file_path = {
            type = "string",
            description = "The path to the file to read."
          }
        },
        required = {"file_path"}
      }
    }
}

local planner_response_format = {
	type = "json_object",
	json_schema = {
		name = "tai_response",
		description = "Response format for the Planner agent",
		schema = {
			type = "object",
			additionalProperties = false,
			properties = {
				writer = {
					type = "string",
					description = "Response for the writer agent",
				},
				coder = {
					type = "string",
					description = "Response for the coder agent",
				},
			}
		}
	}
}

local history = { }

function M.request(model, think, system, prompt, format, callback)
	local url = url .. "/chat"
	local msg = { role = "user", content = prompt }
	table.insert(history, msg)

	local body = { 
		model = model,
		messages = { 
			{ role = "system", content = system },
			unpack(history),
		},
		stream = false,
		-- tools = agents.tools,
	}
	if format then
		body.response_format = format
	end
	if think ~= nil then
		body.think = think
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
			table.insert(history, { role = "assistant", content = parsed.error })
			return { error = parsed.error }
		end

		local message = parsed.message.content
		if not format then
			table.insert(history, { role = "assistant", content = message })
			return message
		end

		local fields = {}
		if message then
			log.debug("response content: " .. message)
			fields = vim.json.decode(message)
			if not fields then
				vim.notify("[tai] Failed to decode message: " .. message, vim.log.levels.ERROR)
				return { error = "[tai] Failed to decode message: " .. message }
			end
			table.insert(history, { role = "assistant", content = fields[1] })
		end
		callback(fields, nil)
	end)
end

return M

