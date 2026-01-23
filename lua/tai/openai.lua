local M = {}

local log = require("tai.log")
local tools = require("tai.tools")
local config = require("tai.config")
local url = "https://api.openai.com/v1/chat/completions"

local api_key = os.getenv("OPENAI_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing OPENAI_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = nil

function M.add_to_history(message)
	local msg = vim.deepcopy(message)
	for _, call in ipairs(msg.tool_calls or {}) do
		local args = call["function"].arguments
		call["function"].arguments = vim.json.encode(args)
	end
	if not history then
		history = { msg }
		return
	end
	table.insert(history, msg)
end

function M.clear_history()
	history = nil
end

function M.request(model_config, msgs, format, callback)
	for _, msg in ipairs(msgs) do
		M.add_to_history(msg)
	end

	local body = {
		model = model_config.model,
		messages = {},
	}

	if config.use_tools ~= false then
		body.tools = {
			tools.defs["read_file"],
			tools.defs["shell"],
			tools.defs["patch"],
			tools.defs["summarize"],
		}
	end
	for _, message in ipairs(history) do
		local new_message = {}
		for key, value in pairs(message) do
			if key ~= "file_path" then
				new_message[key] = value
			end
		end
		table.insert(body.messages, new_message)
	end

	if format then
		body.format = format
	end

	if model_config.options then
		for k, v in pairs(model_config.options) do
			body[k] = v
		end
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. vim.inspect(body))
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
				return callback(nil, "Received empty response from Gemini")
			end

			local parsed = vim.json.decode(obj.stdout)
			if not parsed then
				return callback(nil, "Failed to decode JSON: " .. parsed)
			end
			log.debug("Request response: " .. vim.inspect(parsed))

			if parsed and parsed.error then
				return callback(nil, "Received error: " .. parsed.error.message)
			end

			if parsed.error then
				return callback(nil, parsed.error)
			end

			local message = parsed.choices[1].message
			local content = message.content
			local fields = {}
			if content and content ~= vim.NIL then
				log.debug("response content: " .. content or "")
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

			fields.tool_calls = message.tool_calls
			for _, call in ipairs(fields.tool_calls or {}) do
				local args = call["function"].arguments
				call["function"].arguments = vim.json.decode(args)
			end
			callback(fields, nil)
		end)
end

return M
