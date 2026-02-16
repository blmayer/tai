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
                return callback(nil, "Received empty response from server")
            end

            local parsed = vim.json.decode(obj.stdout)
            if not parsed then
                return callback(nil, "Failed to decode JSON: " .. tostring(obj.stdout))
            end

            if parsed.error then
                return callback(nil, "Received error: " .. parsed.error.message)
            end

            local message = parsed.choices[1].message
            local fields = {}
            if message.content and message.content ~= "" then
                log.debug("response content: " .. message.content)
                if format ~= nil then
                    log.debug("parsing JSON content")
                    fields.content = vim.json.decode(message.content)
                    if not fields.content then
                        return callback(nil, "Failed to decode message")
                    end
                else
                    fields.content = message.content
                end
            end

            fields.tool_calls = message.tool_calls
            provider_common.decode_tool_call_arguments(fields.tool_calls)

            callback(fields, nil)
        end)
end

return M
