local M = {}
local log = require("tai.log")

-- Load config and determine provider
local config = require('tai.config')

-- Load the appropriate provider
local provider
if config.provider == 'groq' then
    provider = require('tai.providers.groq')
elseif config.provider == 'mistral' then
    provider = require('tai.providers.mistral')
else
    error('Unknown chat provider: ' .. provider_name)
end

-- Expose provider functions
M.send = provider.send
M.send_raw = provider.send_raw
M.send_raw_async = provider.send_raw_async

return M
