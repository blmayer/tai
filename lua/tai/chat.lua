local M = {}
local log = require("tai.log")
local config = require('tai.config')

-- Load the appropriate provider
local provider
if config.provider == 'groq' then
    provider = require('tai.providers.groq')
elseif config.provider == 'gemini' then
    provider = require('tai.providers.gemini')
else
    error('Unknown chat provider: ' .. provider_name)
end

local history = {
	{ role = "system", content = "You are edditing a project with root at " .. config.root .. "." },
	{ role = "system", content = provider.system_prompt }
}

-- Expose provider functions
function M.send(model, prompt)
	local msg = { role = "user", content = prompt }
	table.insert(history, msg)
	local reply = provider.send(config.model, history)
	local response = vim.json.encode(reply)
	log.debug("received reply: " .. response)
	table.insert(history, { role = "assistant", content = response })
	return reply
end

M.send_raw = provider.send_raw
M.send_raw_async = provider.send_raw_async

return M
