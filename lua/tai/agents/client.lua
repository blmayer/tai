-- client.lua: Client for interacting with Mistral API using curl

local M = {}

-- Import necessary modules
local log = require('tai.log')
local vim = vim

-- Mistral API configuration
local API_KEY = os.getenv('MISTRAL_API_KEY')
local API_URL = 'https://api.mistral.ai/v1/'

-- Function to make an asynchronous request to the Mistral API
function M.request(method, endpoint, data, callback)
	local url = API_URL .. endpoint
	local request_body = vim.json.encode(data)

	log.debug("Requesting " .. method .. " " .. url .. " with " .. request_body)
	vim.system({
		'curl', '-s', '-X', method, url,
		'-H', 'Content-Type: application/json',
		'-H', 'Authorization: Bearer ' .. API_KEY,
		'-d', request_body
	}, { text = true }, function(obj)
		if obj.code ~= 0 then
			log.error("Mistral API request failed: " .. obj.stderr)
			callback(nil, "Request failed: " .. obj.stderr)
			return
		end

		log.debug("Request response: " .. obj.stdout)
		local response = vim.json.decode(obj.stdout)
		callback(response)
	end)
end

-- Function to make an asynchronous request to the Mistral API
function M.upload(method, endpoint, filepath, callback)
	local url = API_URL .. endpoint
	local request_body = vim.json.encode(data)

	log.debug("Uploading " .. method .. " " .. url .. " with " .. request_body)
	vim.system({
		'curl', '-s', '-X', method, url,
		'-H', 'Authorization: Bearer ' .. API_KEY,
		"-F", "file=@" .. filepath ..";filename=" .. filepath
	}, { text = true }, function(obj)
		if obj.code ~= 0 then
			log.error("Mistral API request failed: " .. obj.stderr)
			callback(nil, "Request failed: " .. obj.stderr)
			return
		end

		log.debug("Request response: " .. obj.stdout)
		local response = vim.json.decode(obj.stdout)
		callback(response)
	end)
end
return M
