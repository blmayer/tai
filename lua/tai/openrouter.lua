local M = {}

local tools = require("tai.tools")
local provider_common = require("tai.provider_common")
local config = require("tai.config")
local log = require("tai.log")
local url = "https://openrouter.ai/api/v1/chat/completions"

local api_key = os.getenv("OPENROUTER_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing OPENROUTER_API_KEY environment variable.", vim.log.levels.ERROR)
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

    -- Keep connected files up to date in history before sending.
    tools.refresh_connected_files(history)

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
            tools.defs["connect_file"],
        }
    end
    for _, message in ipairs(history) do
        local new_message = provider_common.filter_message(message)
        table.insert(body.messages, new_message)
    end

    if format == "json_object" then
        body.response_format = { type = "json_object" }
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
                return callback(nil, "Received empty response from Openrouter")
            end

            local parsed = vim.json.decode(obj.stdout)
            if not parsed then
                return callback(nil, "Failed to decode JSON: " .. obj.stdout)
            end
            log.debug("Request response: " .. vim.inspect(parsed))

            if parsed.error then
                return callback(nil, parsed.error.message)
            end

            if not parsed.choices or #parsed.choices == 0 then
                return callback(nil, "No choices received from Openrouter")
            end

            local message = parsed.choices[1].message
            local fields = {}
            if message.content and message.content ~= "" then
                log.debug("response content: " .. message.content)
                if format == "json_object" then
                    log.debug("parsing JSON content")
                    fields.content = vim.json.decode(message.content)
                    if not fields.content then
                        return callback(nil, "Failed to decode message content as JSON")
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
