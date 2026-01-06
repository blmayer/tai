local M = {}

local log = require('tai.log')
local config = require('tai.config')

M.defs = {
	read_file = {
		type = "function",
		["function"] = {
			name = "read_file",
			description =
			"Reads the full content of a file from the file system, or if given, a range of lines. Don't use `cat` command, use this tool. Returns the content of the file requested.",
			parameters = {
				type = "object",
				properties = {
					file_path = {
						type = "string",
						description = "The path to the file to read."
					},
					range = {
						type = "string",
						description =
						"Optional range of lines to read, starts at 1. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line; Negative numbers are counted from the end: -\\d:$: get last lines. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$; last 5 lines: -5:$.",
					}
				},
				required = { "file_path" }
			}
		}
	},
	patch = {
		type = "function",
		["function"] = {
			name = "patch",
			description = "Writes a change to the file. Returns nil.",
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
						"File name for these changes. relative to the current folder (don't start with /)."
					},
					diff = {
						type = "string",
						description = "Content of the patch in contextual diff format"
					}
				},
				required = { "file", "diff" }
			}
		}
	},
	shell = {
		type = "function",
		["function"] = {
			name = "shell",
			description =
			"Runs commands in a shell in the current folder and returns the output. Use relative paths (don't start with /). Arguments, pipes (|), conditionals (||, &&) and chaining (;)  are allowed. Don't use this for reading files. Returns the otput of the command.",
			parameters = {
				type = "object",
				properties = {
					command = {
						type = "string",
						description =
						    "The pipeline to be interpreted by the shell in the user's machine, usually bash. These are the user approved programs: " ..
						    table.concat(config.allowed_commands, ", ")
					}
				},
				required = { "command" }
			}
		}
	}
}

function M.pretty_info(tools)
	if not tools or #tools == 0 then
		return ""
	end

	local pre = "You can use the following tool calls:\n"
	local tools_desc = vim.tbl_map(
		function(t)
			if not M.defs[t] then
				return ""
			end

			local desc = M.defs[t]["function"].description
			local props = M.defs[t]["function"].parameters.properties
			local args = "Arguments:\n"
			for k, v in pairs(props) do
				args = args .. "- " .. k .. " (" .. v.type .. "): " .. v.description
			end
			return t .. ": " .. desc .. "\n" .. args
		end,
		tools
	)
	return pre .. table.concat(tools_desc, "\n") .. "\n"
end

-- indexes are 0 based
local function parse_range(range)
	-- Handle "$" (last line)
	if range == "$" then
		return -1, -1
	end

	-- Handle negative ranges (e.g., -5:$ for last 5 lines)
	local start, end_line = range:match("^(-%d+):%$")
	if start and end_line then
		return tonumber(start), -1
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

local function read_file(file_path, range)
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

	if not range then
		return table.concat(lines, "\n")
	end

	-- Parse the range
	local start, end_line = parse_range(range)
	if start < 0 or end_line < 0 then
		start = #lines + start + 1
		end_line = #lines + end_line + 1
	end

	local current_line = 1
	local res = {}
	for _, line in ipairs(lines) do
		if current_line >= start and current_line <= end_line then
			table.insert(res, line)
		end

		-- Stop early if we've passed the end of our range
		if current_line > end_line then
			break
		end

		current_line = current_line + 1
	end

	if #res == 0 then
		return "[sys] Invalid range: " .. range
	end

	return table.concat(res, "\n")
end

local function run_command(cmd)
	log.debug("Running `" .. cmd .. "`")

	local env = {}
	for _, name in ipairs({ "PATH" }) do
		env[#env + 1] = name .. "=" .. (os.getenv(name) or "")
	end

	local env_prefix = ""
	for _, v in ipairs(env) do
		local name, value = v:match("^([^=]+)=(.*)$")
		if name and value then
			env_prefix = env_prefix .. name .. "='" .. value:gsub("'", "'\\''") .. "' "
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

	return output
end

local function parse_diff(diff_text)
	local hunk = {
		lines = {},
		old_lines = {},
		new_lines = {}
	}

	local lines = vim.split(diff_text, '\n', { plain = true })

	for i, line in ipairs(lines) do
		if line:sub(1, 2) == "\\-" or line:sub(1, 2) == "\\+" then
			-- To avoid diffs starting and ending with context
			if hunk.order == "op-ctx" then
				return nil, "error: context on start and end"
			end
			hunk.order = "ctx-op"
			-- Remove the escape character and treat as context
			local unescaped_line = line:sub(2)
			table.insert(hunk.lines, unescaped_line)
			goto continue_label
		end

		-- Check for context lines (lines without - or + prefix)
		if line:sub(1, 1) ~= "-" and line:sub(1, 1) ~= "+" then
			-- To avoid diffs starting and ending with context
			if hunk.order == "op-ctx" then
				return nil, "error: context on start and end"
			end
			hunk.order = "ctx-op"
			table.insert(hunk.lines, line)
			goto continue_label
		end

		-- Start of a hunk
		if line:sub(1, 1) == "-" then
		    if #hunk.lines == 0 then
			hunk.order = "op-ctx"
		    end

		    table.insert(hunk.old_lines, line:sub(2))
		elseif line:sub(1, 1) == "+" then
		    if #hunk.lines == 0 then
			hunk.order = "op-ctx"
		    end
		    table.insert(hunk.new_lines, line:sub(2))
		end

		::continue_label::
	end

	log.debug("Parsed hunk: " .. vim.inspect(hunk))
	return hunk
end

-- Add a helper function to trim whitespace
local function trim(s)
	return s:gsub("^%s*(.-)%s*$", "%1")
end

-- Update the context matching logic in apply_diff
local function apply_diff(file_path, hunk)
	local buf = nil

	-- Check if file is already open in a buffer
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
		    local buf_name = vim.api.nvim_buf_get_name(b)
		    if buf_name:match("^.*/" .. file_path .. "$") or buf_name == file_path then
			buf = b
			break
		    end
		end
	end

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
		vim.cmd("topleft vnew " .. file_path)
		buf = vim.api.nvim_get_current_buf()
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

	-- Find the location to apply the patch
	local start_line = 1
	local found = false

	if #hunk.lines > 0 then
		-- Search for context lines with trimmed whitespace
		for j = 1, #lines - #hunk.lines + 1 do
			local match = true
			for k = 1, #hunk.lines do
				local file_line = trim(lines[j + k - 1])
				local patch_line = trim(hunk.lines[k])
				if file_line ~= patch_line then
					match = false
					break
				end
			end
			if match then
				found = true
				if hunk.order == "ctx-op" then
					start_line = j + #hunk.lines
				else
					start_line = j
				end
				log.debug("found match on line " .. start_line)
				break
			end
		end
	else
		if #hunk.old_lines > 0 then
			-- Search for old content directly with trimmed whitespace
			for j = 1, #lines - #hunk.old_lines + 1 do
				local match = true
				for k = 1, #hunk.old_lines do
					local file_line = trim(lines[j + k - 1])
					local patch_line = trim(hunk.old_lines[k])
					if file_line ~= patch_line then
						match = false
						break
					end
				end
				if match then
					found = true
					start_line = j
					log.debug("found match on line " .. start_line)
					break
				end
			end
		else
			-- Adding to empty file or at the beginning
			found = true
			start_line = 1
			log.debug("adding to empty file at line " .. start_line)
		end
	end

	if not found then
		return false, "could not find location to apply patch"
	end

	-- Remove old lines
	for j = 1, #hunk.old_lines do
		log.debug("removing line")
		table.remove(lines, start_line)
	end

	-- Insert new lines
	for j = #hunk.new_lines, 1, -1 do
		log.debug("inserting line " .. j)
		table.insert(lines, start_line, hunk.new_lines[j])
	end

	-- Write the modified content back to the buffer
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	return true
end

function M.run(tool, args)
	log.debug("Running tool call")

	if tool == "read_file" then
		if not args.file_path then
			return "[sys] missing read_file argument"
		end
		return read_file(args.file_path)
	elseif tool == "shell" then
		if not args.command then
			return "[sys] missing command argument"
		end
		return run_command(args.command)
	elseif tool == "patch" then
		if not args.file or not args.diff then
			return "[sys] missing file or change arguments"
		end

		-- Parse the contextual diff
		local hunk, err = parse_diff(args.diff)
		if not hunk then
			return "[sys] no valid hunks found in patch: " .. err
		end

		local ok, err = apply_diff(args.file, hunk)
		if not ok then
			return "[sys] " .. err
		else
			return "[sys] patch applied and submitted for user approval"
		end
	else 
		return "[sys] unknown tool `" .. tool .. "`"
	end
end

return M
