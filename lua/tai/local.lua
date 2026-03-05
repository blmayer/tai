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

return M
