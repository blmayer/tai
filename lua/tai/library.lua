-- library.lua: Library management for Tai

local M = {
	cache = {},
}

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

-- Function to list existing file in library
function M.files(callback)
	log.debug("getting files")
	client.request("GET", 'libraries/' .. M.id .. "/documents", {}, function(response, err)
		if err then
			log.error("Failed to list files: " .. err)
			callback(nil, err)
		else
			callback(response.data)
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
	local file_stat = vim.uv.fs_stat(filepath)

	client.upload(
		"POST",
		'libraries/' .. M.id .. '/documents',
		filepath,
		function(response, err)
			if err then
				log.error("Failed to upload file: " .. filepath .. " - " .. err)
				callback(nil, err)
			else
				if not response or not response.id then
					callback(nil, "Failed to upload file: empty response")
					return
				end

				log.info("Uploaded file: " .. filepath .. " with ID: " .. response.id)
				M.cache[filepath] = {
					id = response.id,
					hash = response.hash,
					creation_time = file_stat.mtime
					    .sec
				}
				callback(response.id)
			end
		end
	)
end

function M.sync(files)
	M.files(function(libs, err)
		if err then
			log.error("Failed to sync files: " .. err)
			return
		end
		log.debug("Got list of files in library: " ..
			table.concat(vim.tbl_map(function(item) return item.name end, libs), ", "))

		for i, filepath in ipairs(files) do
			if vim.fn.isdirectory(filepath) == 1 then
				goto next
			end

			local file_stat = vim.uv.fs_stat(filepath)
			for _, lib in ipairs(libs) do
				if lib.name == filepath then
					local updated_at = parse_iso_date(lib.updated_at or lib.created_at)
					if file_stat.mtime.sec <= updated_at then
						log.debug(filepath .. " is up to date, skipping.")
						M.cache[filepath] = {
							id = lib.id,
							hash = lib.hash,
							creation_time = lib.created_at
							    .sec
						}
						goto next
					end
					break
				end
			end

			log.debug("Scheduling upload of " .. filepath .. " with delay of " .. i * 8)
			vim.defer_fn(function()
				log.info("Uploading " .. filepath)
				M.upload_file(filepath, function(_, err)
					if err then
						log.error("Failed to upload: " .. filepath .. " - " .. err)
					end
				end)
			end, i * 8000)

			::next::
		end

		--TODO: delete files
	end)
end

return M
