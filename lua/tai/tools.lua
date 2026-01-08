local M = {}

local log = require('tai.log')
local config = require('tai.config')

M.defs = {
	read_file = {
		type = "function",
		["function"] = {
			name = "read_file",
			description =
			"Reads the full content of a file from the file system, or if given, a range of lines. And returns the content with numberred lines. Don't use `cat` command, use this tool. Returns the content of the file requested.",
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
			description =
			"Applies the given changes in order. Please double check the line numbers match, they are altered by previouls changes. Returns nil.",
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
						"List of changes to be made. Each change is applied in order, so you must keep track of how line numbers change.",
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
									"String with the range of lines on the original file that the operation is on, starts at 1. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line. Note: to add before the first line use 0. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$.",
								},
								content = {
									type = "string",
									description =
									"New contente to be inserted. Not used for delete operation. Don't add line numbers.",
								}
							},
							required = { "operation", "lines" }
						}
					}
				},
				required = { "file", "changes" }
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

	local numbered_lines = {}
	if not range then
		-- If no range is specified, return all lines
		for i, line in ipairs(lines) do
			table.insert(numbered_lines, string.format("%d: %s", i, line))
		end
		local numbered_content = table.concat(numbered_lines, "\n")
		log.debug("read_file output: " .. numbered_content)
		return numbered_content
	end

	-- Parse the range
	local start, end_line = parse_lines(range)
	if start < 0 or end_line < 0 then
		start = lines + start + 1
		end_line = lines + end_line + 1
	end

	for i, line in ipairs(lines) do
		if i >= start and i <= end_line then
			table.insert(numbered_lines, string.format("%d: %s", i, line))
		end

		-- Stop early if we've passed the end of our range
		if i > end_line then
			break
		end
	end

	if #numbered_lines == 0 then
		return "[sys] Invalid range: " .. range
	end

	local numbered_content = table.concat(numbered_lines, "\n")
	log.debug("read_file output: " .. numbered_content)
	return numbered_content
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
	log.debug("command output: " .. output)

	return output
end

local function apply_patch(name, file, changes)
	log.debug("Patching " .. #changes .. " changes in " .. file)

	-- Check if file is already open in a buffer
	local buf = nil
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			local buf_name = vim.api.nvim_buf_get_name(b)
			if buf_name:match("^.*/" .. file .. "$") or buf_name == file then
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
		vim.cmd("topleft vnew " .. file)
		buf = vim.api.nvim_get_current_buf()
	end

	-- Apply changes to new buffer (replace with your actual diff content)
	for _, hunk in ipairs(changes) do

		-- local new_buf = vim.api.nvim_create_buf(0, false)

		-- Copy lines from current buffer to new buffer
		-- local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		-- vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)

		local operation = hunk.operation
		local lines_str = hunk.lines
		local content = hunk.content

		-- Parse line range
		local start, end_line = parse_lines(lines_str)

		if operation == "add" then
			-- Insert content after the specified lines
			local new_lines = vim.split(content, '\n')
			if lines_str ~= "0" then -- If not adding before the first line (which uses index 0)
				start = start + 1
			end
			vim.api.nvim_buf_set_lines(buf, start, start, false, new_lines)
		elseif operation == "change" then
			-- Replace lines with new content
			local new_lines = vim.split(content, '\n')
			vim.api.nvim_buf_set_lines(buf, start, end_line + 1, false, new_lines)
		elseif operation == "delete" then
			-- Remove lines
			vim.api.nvim_buf_set_lines(buf, start, end_line + 1, false, {})
		end

		-- -- generate unified diff text directly in Lua
		-- local new_lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
		-- local diff_text = vim.diff(
		-- 	table.concat(lines, "\n"),
		-- 	table.concat(new_lines, "\n"),
		-- 	{ result_type = "unified" }
		-- )

		-- -- split into lines for display
		-- local diff_lines = vim.split(diff_text, "\n", { plain = true })

		-- -- create a scratch buffer
		-- local diff_buf = vim.api.nvim_create_buf(false, true)
		-- vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
		-- vim.bo[diff_buf].filetype = "diff"
		-- vim.bo[diff_buf].modifiable = false

		-- local win = vim.api.nvim_get_current_win()
		-- vim.api.nvim_win_set_buf(win, new_buf)

		-- vim.api.nvim_buf_create_user_command(
		-- 	buf,
		-- 	'AcceptPatch',
		-- 	function()
		-- 		-- Accept changes (this is the critical part)
		-- 		vim.cmd('w ' .. file)
		-- 	end,
		-- 	{ nargs = 0 }
		-- )
	end
end

-- TODO: there must be an enum for tool names
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
		if not args.file then
			return "[sys] missing file argument"
		end
		if not args.changes then
			return "[sys] missing changes argument"
		end
		local err = apply_patch(args.name, args.file, args.changes)
		if err then
			return "[sys] patch error: " .. err
		end
		return "[sys] patch applied and submitted for user approval"
	end

	return "[sys] Unknown tool `" .. tool .. "`"
end

return M
