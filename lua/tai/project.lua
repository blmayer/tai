local M = {}

local log = require('tai.log')
local config = require("tai.config")
local agents = require("tai.agents")
local library = require("tai.library")
local planner = require("tai.agents.planner")

local completion_prompt =
"You are an autocomplete assistant. You will receive the current line, you job is to return the remaining part, don't add any formatting. Line:\n"

function M.init()
	if not config then
		return
	end
	if config.skip_cache then
		return
	end

	local files = vim.fn.glob('**/*', true, true)
	library.setup(function(library_id, err)
		if err then
			log.error("Failed to setup library: " .. err)
			return
		end
		log.info("Library initialized with ID: " .. library_id)

		agents.init()
		log.info("Agents init complete")

		log.info("Uploading project files")
		for _, filepath in ipairs(files) do
			log.debug("Checking file " .. filepath)
			if vim.fn.isdirectory(filepath) == 0 then
				library.is_file_in_library(filepath, function(exists, err)
					if err then
						log.error("Failed to check file in library: " .. filepath .. " - " .. err)
					elseif not exists then
						log.info("Uploading file " .. filepath)
						library.upload_file(filepath, function(file_id, err)
							if err then
								log.error("Failed to upload file: " ..
									filepath .. " - " .. err)
							end
						end)
					end
				end)
			end
			os.execute("sleep 5")
		end
	end)
end

function M.process_request(prompt, callback)
	planner.receive_prompt(prompt, callback)
end

--function M.complete(start)
--	-- Get current buffer content
--	local bufnr = vim.api.nvim_get_current_buf()
--	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
--	local content = table.concat(lines, "\n")
--
--	local msgs = {
--		{ role = "system",    content = content },
--		{ role = "user",      content = completion_prompt .. start },
--		{ role = "assistant", content = start }
--	}
--
--	local reply = chat.send_raw(config.complete_model, msgs)
--	if not reply then return nil end
--
--	return reply
--end

return M
