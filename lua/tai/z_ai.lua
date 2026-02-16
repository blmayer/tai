local M = {}

local provider_common = require("tai.provider_common")
local tools = require("tai.tools")
local config = require("tai.config")
local config = require("tai.config")

local url = "https://api.z.ai/api/paas/v4/chat/completions"

local api_key = os.getenv("Z_AI_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing Z_AI_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local history = nil

function M.add_to_history(message)
	if not history then
		history = {message}
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

	-- Keep connected files up to date in history before sending.
	tools.refresh_connected_files(history)

    local agent_tools = provider_common.build_agent_tools(model_config)
	local body = {
		model = model_config.model,
        messages = provider_common.filter_message(history) or {},
		tools = agent_tools,
	}
	if format then
		body.format = format
	end
    if config.use_tools ~= false and #agent_tools > 0 then
        body.tools = agent_tools
	end
	if model_config.think ~= nil then
		body.reasoning_effort = model_config.think
	end
	if model_config.options then
		body.extra_body = model_config.options
	end

	local request_body = vim.json.encode(body)

	log.debug("Requesting " .. url .. " with " .. vim.inspect(request_body))
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
				return callback(nil, parsed.error.message)
			end

			local message = parsed.choices[1].message
			local content = message.content
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

            fields.tool_calls = message.tool_calls
            provider_common.decode_tool_call_arguments(fields.tool_calls)
			callback(fields, nil)
		end)
end

return M
