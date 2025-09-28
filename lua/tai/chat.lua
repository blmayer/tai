local M = {}
local log = require("tai.log")
local config = require('tai.config')

if not config.root then
	return M
end

-- Load the appropriate provider
local provider
if config.provider == 'groq' then
	provider = require('tai.providers.groq')
elseif config.provider == 'gemini' then
	provider = require('tai.providers.gemini')
elseif config.provider == nil then
	-- do nothing
else
	error('Unknown chat provider: ' .. config.provider)
end

local history = {
	{ role = "system", content = "You are edditing a project with root at " .. config.root .. "." },
	{ role = "system", content = provider.system_prompt }
}

function M.send(model, prompt)
	local msg = { role = "user", content = prompt }
	table.insert(history, msg)

	local reply_data = provider.send(config.model, history)
	log.debug("received reply: " .. vim.json.encode(reply_data))
	local assistant_message_content = reply_data.content
	table.insert(history, { role = "assistant", content = assistant_message_content })

	return reply_data
end

M.send_raw = provider.send_raw
M.send_raw_async = provider.send_raw_async

return M
