-- library.lua: Library management for Tai

local M = {}

-- Import necessary modules
local log = require('tai.log')
local client = require('tai.agents.client')
local config = require('tai.config')

-- Function to parse ISO 8601 date string to Unix timestamp
local function parse_iso_date(iso_date)
	local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+).(%d+)Z"
	local year, month, day, hour, min, sec, msec = iso_date:match(pattern)
	local timestamp = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = sec })
	return timestamp
end

-- Function to list existing libraries in Mistral
function M.list(callback)
	client.request("GET", 'libraries', {}, function(response, err)
		if err then
			log.error("Failed to list libraries: " .. err)
			callback(nil, err)
		else
			local existing_libraries = {}
			for _, library in ipairs(response.data) do
				existing_libraries[library.name] = library.id
			end
			callback(existing_libraries)
		end
	end)
end

-- Function to setup a library using the Mistral library API
function M.setup(callback)
	log.info("Checking for library " .. config.root)
	M.list(function(existing_libraries, err)
		if err then
			log.error("Failed to list libraries: " .. err)
			callback(nil, err)
			return
		end

		local library_name = config.root
		if existing_libraries[library_name] then
			log.info("Library " ..
				library_name .. " already exists with ID: " .. existing_libraries[library_name])
			M.id = existing_libraries[library_name]
			callback(M.id)
		else
			client.request("POST", 'libraries', { name = library_name }, function(response, err)
				if err then
					log.error("Failed to setup library: " .. err)
					callback(nil, err)
				else
					log.info("Library setup with ID: " .. response.id)
					M.id = response.id
					callback(response.id)
				end
			end)
		end
	end)
end

-- Function to upload a file to the library
function M.upload_file(filepath, callback)
	local file_content = table.concat(vim.fn.readfile(filepath), '\n')
	local file_stat = vim.uv.fs_stat(filepath)

	client.request("POST", 'libraries/' .. config.library_id .. '/files', {
		name = filepath,
		content = file_content
	}, function(response, err)
		if err then
			log.error("Failed to upload file: " .. filepath .. " - " .. err)
			callback(nil, err)
		else
			log.info("Uploaded file: " .. filepath .. " with ID: " .. response.id)
			M.files[filepath] = {
				id = response.id,
				hash = response.hash,
				creation_time = file_stat.mtime
				    .sec
			}
			callback(response.id)
		end
	end)
end

-- Function to check if a file is in the library
function M.is_file_in_library(filepath, callback)
	local file_stat = vim.uv.fs_stat(filepath)

	client.request("GET", 'libraries/' .. M.id .. '/documents?search=' .. filepath, {}, function(response, err)
		if err then
			log.error("Failed to list files in library: " .. err)
			callback(nil, err)
		else
			for _, file in ipairs(response.data) do
				if file.name == filepath then
					local updated_at = parse_iso_date(response.updated_at)
					if file_stat.mtime.sec <= updated_at then
						callback(true)
						return
					end
				end
			end
			callback(false)
		end
	end)
end

return M
