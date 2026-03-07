local M = {}

local log = require('tai.log')

M.summary_msg = {
	role = "user",
	content = [[
Summarize all our prompts so far, don't include any file content. Follow this:
- Retain any important info about the project, file structure etc
- Make a brief summary of the chat.
- if there is an ongoing operation also include:
  - important file content.
  - the task definition, progress and the next steps.
]]
}

M.defs = {
	{
		type = "function",
		["function"] = {
			name = "connect_file",
			description =
			"Adds a file's content to the conversation and keeps it updated. Use this to track files that are being actively worked on - the content will automatically refresh when changes are made.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "The path to the file to read."
					},
					range = {
						type = "string",
						description =
						"Optional range of lines to read, starts at 1. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line; Negative numbers are counted from the end: -\\d:$: get last lines. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$; last 5 lines: -5:$.",
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	{
		type = "function",
		["function"] = {
			name = "patch",
			description =
			"Edits files using line-based operations. All 'lines' values are 1-based and reference the current file state. So a patch is affected by previous ones. All changes in a patch the the same file state.",
			parameters = {
				type = "object",
				properties = {
					name = {
						type = "string",
						description =
						"Name for this patch or description, can be used for commits."
					},
					file = {
						type = "string",
						description =
						"File name for these changes. Relative to the project's folder (don't start with /)."
					},
					changes = {
						type = "array",
						description =
						"List of changes to be made. All changes will use the ORIGINAL state of the file.",
						items = {
							type = "object",
							properties = {
								operation = {
									type = "string",
									description =
									"Operation of this change: add will append new content after the line; change will substitute the range with the new content; delete will erase the lines in range.",
									enum = { "add", "change", "delete" }
								},
								lines = {
									type = "string",
									description =
									"1-based: N (single), N:M (range), $ (last), -N:$ (last N), -N (Nth from end), 0 (before first)",
								},
								content = {
									type = "string",
									description =
									"New content (empty for delete operation)",
								}
							},
							additionalProperties = false,
							required = { "operation", "lines", "content" }
						}
					}
				},
				additionalProperties = false,
				required = { "file", "changes", "name" }
			}
		}
	},
	{
		type = "function",
		["function"] = {
			name = "shell",
			description =
			"Runs commands in a shell in the current folder and returns the output. Use relative paths (don't start with /). Arguments, pipes (|), conditionals (||, &&) and chaining (;)  are allowed. Don't use this for reading or writing files, use read_file and patch tools respectively. Returns the otput of the command.",
			parameters = {
				type = "object",
				properties = {
					command = {
						type = "string",
						description =
						"The pipeline to be interpreted by the shell in the user's machine, usually bash."
					}
				},
				additionalProperties = false,
				required = { "command" }
			}
		}
	},
	{
		type = "function",
		["function"] = {
			name = "summarize",
			description =
			"Summarizes the chat history to reduce context size. This should be used when the conversation is getting too long and the context is becoming too large. Calling this function will replace the history.",
			parameters = {
				type = "object",
				properties = vim.empty_dict(),
				additionalProperties = false
			}
		}
	},
	{
		type = "function",
		["function"] = {
			name = "send_image",
			description =
			"Use this tool to send images to the agent so it can see and interpret screenshots, diagrams, UI mockups, error messages, or any visual content.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "The path to the image file to send."
					},
					prompt = {
						type = "string",
						description = "Optional prompt to guide what to look for in the image."
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
}

-- indexes are 1 based
local function parse_lines(range)
	-- Handle "$" (last line)
	if range == "$" then
		return -1, -1
	end

	-- Handle negative ranges (e.g., -5:$ for last 5 lines)
	local start, end_line = range:match("^(-%d+):%$")
	if start and end_line then
		return tonumber(start), -1
	end

	-- Handle positive-to-$ ranges (e.g., 10:$ for tenth to last line)
	local dollar_pos = range:match("():%$")
	if dollar_pos and dollar_pos > 1 then
		local start_num = tonumber(range:sub(1, dollar_pos - 1))
		if start_num then
			return start_num - 1, -1
		end
	end

	-- Handle range (e.g., "2:5")
	start, end_line = range:match("^(%d+):(%d+)$")
	if start and end_line then
		return tonumber(start) - 1, tonumber(end_line) - 1
	end

	-- Handle single line (e.g., "3")
	local line = tonumber(range)
	if line == 0 then
		return 0, 0
	end
	if line then
		return line - 1, line - 1
	end

	return 0, 0
end

function M.read_file(file_path, range)
	log.debug("Running read_file `" .. file_path .. "` with range: " .. (range or "nil"))

	if file_path:sub(1, 1) == "/" then
		return "[sys] Paths cannot start from root (/). Use relative."
	end

	-- Check if file is already open in a buffer
	local buf = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			local buf_name = vim.api.nvim_buf_get_name(b)
			if buf_name:match("^.*/" .. file_path .. "$") or buf_name == file_path then
				buf = b
				break
			end
		end
	end

	local lines
	if buf then
		log.debug("reading from buffer")
		lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	else
		log.debug("reading from file")
		local file = io.open(file_path, "r")
		if not file then
			return "[sys] File `" ..
			    file_path .. "` not found. Hint: check if it exists with the shell command: ls -R."
		end
		local content = file:read("*all")
		file:close()
		lines = vim.split(content, '\n', { plain = true })
	end

	local numbered_lines = {}
	if not range or range == "" then
		-- If no range is specified, return all lines
		for i, line in ipairs(lines) do
			table.insert(numbered_lines, string.format("%d: %s", i, line))
		end
		local numbered_content = table.concat(numbered_lines, "\n")
		log.debug("read_file output: " .. numbered_content)
		return numbered_content
	end

	-- Parse the range (parse_lines returns 0-based indexes for patch usage)
	local start0, end0 = parse_lines(range)
	local nlines = #lines

	-- Convert negative indexes (relative to end) to 0-based absolute indexes
	if start0 < 0 then
		start0 = nlines + start0
	end
	if end0 < 0 then
		end0 = nlines + end0
	end

	-- Convert to 1-based for display
	local start1 = start0 + 1
	local end1 = end0 + 1

	-- Clamp end1 to valid range (allow exceeding file length)
	if end1 > nlines then
		end1 = nlines
	end

	if start1 < 1 or end1 < 0 or start1 > nlines or start1 > end1 then
		return "[sys] Invalid range: " .. range
	end

	for i = start1, end1 do
		table.insert(numbered_lines, string.format("%d: %s", i, lines[i]))
	end

	local numbered_content = table.concat(numbered_lines, "\n")
	log.debug("read_file output: " .. numbered_content)
	return numbered_content
end

function M.check_command(cmd)
	log.debug("Running `" .. cmd .. "`")

	local config = require("tai.config")
	local allowed = config.get_allowed_commands()

	-- Extract the base command (first word)
	local base_cmd = cmd:match("^%s*(%w+)")
	local is_allowed = base_cmd and allowed[base_cmd]

	-- Return the base command and whether it's allowed
	return base_cmd, is_allowed
end

function M.exec_command(cmd)
	log.debug("Executing `" .. cmd .. "`")

	local env = {}
	for _, name in ipairs({ "PATH" }) do
		env[#env + 1] = name .. "=" .. (os.getenv(name) or "")
	end

	local env_prefix = ""
	for _, v in ipairs(env) do
		local name, value = v:match("^([^=]+)=(.*)$")
		if name and value then
			env_prefix = env_prefix .. name .. "='" .. value:gsub("'", "'\\\\'") .. "' "
		end
	end

	local full_cmd = env_prefix .. cmd .. " 2>&1"
	local handle = io.popen(full_cmd, "r")
	if not handle then
		return nil, "Failed to run command"
	end

	local output = handle:read("*a")
	handle:close()

	if not output then
		output = "[sys] `" .. cmd .. "` returned null"
	end
	log.debug("command output: " .. output)

	return output
end

function M.apply_patch(name, file, changes)

	local buf = nil
	local is_open = false

	if buf then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == buf then
				is_open = true
				break
			end
		end
	end
	if not is_open or not buf then
		-- File not loaded yet, create new buffer and window
		vim.cmd("topleft vnew " .. file)
		buf = vim.api.nvim_get_current_buf()
	end


	-- Ensure parent directory exists before writing
	local dir = vim.fn.fnamemodify(file, ":p:h")
	if dir and dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
		local mkdir_result = vim.fn.mkdir(dir, "p")
		if mkdir_result == -1 then
			return "[sys] Error: Could not create directory: " .. dir
		end
	end

	-- If buffer already exists (visible or not), reuse it directly.
	-- No need to open a window since we modify via nvim_buf_set_lines API.

	-- Apply changes to new buffer
	-- vim.api.nvim_buf_set_lines is 0 indexed
	local line_shift = 0
	if type(changes) ~= "table" then
		return "changes must be an array, got " .. type(changes)
	end
	for _, hunk in ipairs(changes) do
		local operation = hunk.operation
		local lines_str = hunk.lines
		local content = hunk.content

		-- Get current state of buffer
		local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local total_lines = #current_lines

		-- Parse line range
		local start, end_line = parse_lines(lines_str)

		-- Adjust for line shift from previous changes
		local adjusted_start = start + line_shift
		local adjusted_end = end_line + line_shift

		-- Clamp to valid ranges
		if end_line == -1 then adjusted_end = -1 end
		if adjusted_start < 0 then adjusted_start = 0 end
		if adjusted_end >= total_lines then adjusted_end = total_lines - 1 end

		if operation == "add" then
			-- Insert content after the specified line
			local new_lines = vim.split(content, '\n')
			local insert_pos = adjusted_end + 1
			if lines_str == "0" then
				insert_pos = 0
			end
			vim.api.nvim_buf_set_lines(buf, insert_pos, insert_pos, false, new_lines)
			-- Track the addition for subsequent changes
			line_shift = line_shift + #new_lines
		elseif operation == "change" then
			-- Replace lines with new content
			local new_lines = vim.split(content, '\n')
			local old_line_count = adjusted_end - adjusted_start + 1
			local new_line_count = #new_lines
			vim.api.nvim_buf_set_lines(buf, adjusted_start, adjusted_end + 1, false, new_lines)
			-- Track the net change for subsequent changes
			line_shift = line_shift + (new_line_count - old_line_count)
		elseif operation == "delete" then
			-- Remove lines
			local old_line_count = adjusted_end - adjusted_start + 1
			vim.api.nvim_buf_set_lines(buf, adjusted_start, adjusted_end + 1, false, {})
			-- Track the deletion for subsequent changes
			line_shift = line_shift - old_line_count
		end
	end

	-- Save the buffer to disk (explicitly target our buffer to avoid conflicts)
	vim.api.nvim_buf_call(buf, function() vim.cmd("write!") end)
	return "[sys] Patched " .. file
end

-- Convert image file to base64 data URL
function M.image_data_url(image_path)
	local full_path = image_path

	-- Handle relative paths (relative to project root or CWD)
	if image_path:sub(1, 1) ~= "/" then
		-- Try project root first
		local config = require("tai.config")
		if config.root then
			local try_path = config.root .. "/" .. image_path
			if vim.fn.filereadable(try_path) == 1 then
				full_path = try_path
			end
		end
	end

	-- Check if file exists
	if vim.fn.filereadable(full_path) ~= 1 then
		-- Try as absolute path
		if vim.fn.filereadable(image_path) == 1 then
			full_path = image_path
		else
			return nil, "Image file not found: " .. image_path
		end
	end

	-- Detect MIME type from extension
	local ext = image_path:match("%.(%w+)$")
	local mime_types = {
		png = "image/png",
		jpg = "image/jpeg",
		jpeg = "image/jpeg",
		gif = "image/gif",
		webp = "image/webp",
		bmp = "image/bmp",
	}
	local mime = mime_types[ext:lower()] or "image/png"

	-- Read file and encode to base64 using curl
	local cmd = string.format("base64 -i '%s' | tr -d '\n'", full_path)
	local handle = io.popen(cmd, "r")
	if not handle then
		return nil, "Failed to read image file"
	end
	local base64_content = handle:read("*a")
	handle:close()

	if not base64_content or #base64_content == 0 then
		return nil, "Failed to encode image to base64"
	end

	return "data:" .. mime .. ";base64," .. base64_content, nil
end

function M.refresh_connected_files(history)
	-- Walk from the end so we can detect older connect_file calls for the same file.
	local latest = {}
	for i = #history, 1, -1 do
		local msg = history[i]
		if msg and msg.role == "tool" and msg.name == "connect_file" and msg.file_path then
			local key = msg.file_path .. "::" .. (msg.file_range or "")
			if latest[key] then
				msg.content = "[sys] content shown in newer call"
				msg.file_path = nil
				msg.file_range = nil
			else
				latest[key] = true
			end
		end
	end

	-- Refresh remaining (latest) connect_file messages.
	for _, msg in ipairs(history or {}) do
		if msg and msg.role == "tool" and msg.name == "connect_file" and msg.file_path then
			msg.content = M.read_file(msg.file_path, msg.file_range or "")
		end
	end
end

return M
