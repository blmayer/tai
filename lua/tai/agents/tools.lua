local M = {}

local log = require('tai.log')
local config = require('tai.config')

M.defs = {
	read_file = {
		type = "function",
		["function"] = {
			name = "read_file",
			description =
			"Reads the content of a file from the file system. And returns the content with numberred lines.",
			parameters = {
				type = "object",
				properties = {
					file_path = {
						type = "string",
						description = "The path to the file to read."
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
			"Creates a patch from the given changes, please double check the line numbers. This will ask for user approval and will not return.",
			parameters = {
				type = "object",
				properties = {
					name = {
						type = "string",
						description = "Name for this patch"
					},
					changes = {
						type = "array",
						description =
						"List of changes to be made, by file. Each change is applied independently on the original file, i.e. the order matters, but line numbers are not updated.",
						items = {
							type = "object",
							properties = {
								file = {
									type = "string",
									description =
									"File name for these changes. relative to the current folder (don't start with /)."
								},
								hunks = {
									type = "array",
									description = "List of changes for this file.",
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
												"Range of lines on the original file that the operation is on, starts at 1. Formats: \\d: single line; \\d-\\d: inclusive range; $: last line. Note: to add before the first line use 0.",
											},
											content = {
												type = "string",
												description =
												"New content. Not used for delete operation.",
											},
										},
										required = { "operation", "lines" }
									}
								}
							},
							required = { "file", "hunks" }
						}
					}
				},
				required = { "changes" }
			}
		}
	},
	run = {
		type = "function",
		["function"] = {
			name = "run",
			description =
			"Runs commands in a shell in the current folder and returns the output. Use relative paths (don't start with /). Arguments, pipes (|), conditionals (||, &&) and chaining (;)  are allowed.",
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

local function read_file(file_path)
	log.debug("Running read_file `" .. file_path .. "`")

	if file_path:sub(1, 1) == "/" then
		return "[sys] Paths cannot start from root (/). Use relative."
	end

	local file = io.open(file_path, "r")
	if not file then
		return "[sys] File `" .. file_path .. "` not found."
	end

	local content = file:read("*all")
	file:close()

	local numbered_lines = {}
	for i, line in ipairs(vim.split(content, '\n', { plain = true })) do
		table.insert(numbered_lines, string.format("%d: %s", i, line))
	end
	local numbered_content = table.concat(numbered_lines, "\n")

	log.debug("read_file output: " .. numbered_content)
	return numbered_content
end

local function dangerous_command(cmd)
	local parts = vim.split(cmd, "%s+")
	if #parts == 0 then return false end

	local base = parts[1]:match("^([^/]+)$")
	if not base then
		return nil
	end

	local ok = false
	for _, c in ipairs(config.allowed_commands) do
		if c == base then
			ok = true
			break
		end
	end

	if not ok then
		return "[sys] Command not allowed."
	end

	for _, arg in ipairs(parts) do
		if arg:sub(1, 1) == "-" then
			goto continue
		end
		if arg:sub(1, 1) == "/" then
			return "[sys] Paths cannot start from root (/). Use relative."
		end
		if arg:match("%.%.") then
			return false
		end
		if arg:match("[*?]") then
			return false
		end
		::continue::
	end

	return nil
end

local function run_command(cmd)
	log.debug("Running run `" .. cmd .. "`")

	local danger = dangerous_command(cmd)
	if danger then
		log.debug("command is not allowed: " .. danger)
		return "[sys] Command not executed because: " .. danger
	end

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

local function parse_lines(lines_str)
	-- Handle "$" (last line)
	if lines_str == "$" then
		return -1, -1
	end

	-- Handle range (e.g., "2-5")
	local start, end_line = lines_str:match("^(%d+)-(%d+)$")
	if start and end_line then
		return tonumber(start), tonumber(end_line)
	end

	-- Handle single line (e.g., "3")
	local line = tonumber(lines_str)
	if line then
		return line, line
	end

	return 1, 1
end

local function apply_patch(name, changes)
	log.debug("Running patch in " .. #changes .. " file(s).")

	-- Apply changes to new buffer (replace with your actual diff content)
	for _, change in ipairs(changes) do
		local file = change.file

		vim.cmd("vs " .. file)
		local buf = vim.api.nvim_get_current_buf()
		-- local new_buf = vim.api.nvim_create_buf(0, false)

		-- Copy lines from current buffer to new buffer
		-- local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		-- vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)

		for _, hunk in ipairs(change.hunks) do
			local operation = hunk.operation
			local lines_str = hunk.lines
			local content = hunk.content

			-- Parse line range
			local start, end_line = parse_lines(lines_str)

			if operation == "add" then
				-- Insert content after the specified lines
				local new_lines = vim.split(content, '\n')
				vim.api.nvim_buf_set_lines(buf, start, end_line, false, new_lines)
			elseif operation == "change" then
				-- Replace lines with new content
				local new_lines = vim.split(content, '\n')
				vim.api.nvim_buf_set_lines(buf, start, end_line, false, new_lines)
			elseif operation == "delete" then
				-- Remove lines
				vim.api.nvim_buf_set_lines(buf, start, end_line, false, {})
			end
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

		vim.api.nvim_buf_create_user_command(
			buf,
			'AcceptPatch',
			function()
				-- Accept changes (this is the critical part)
				vim.cmd('w ' .. file)
			end,
			{ nargs = 0 }
		)
	end
end

-- TODO: there must be an enum for tool names
function M.run(cmd)
	log.debug("Running tool call")

	local tool = cmd["function"]["name"]
	local args = cmd["function"].arguments

	if tool == "read_file" then
		if not args.file_path then
			return "[sys] missing read_file argument"
		end
		return read_file(args.file_path)
	elseif tool == "run" then
		if not args.command then
			return "[sys] missing command argument"
		end
		return run_command(args.command)
	elseif tool == "patch" then
		if not args.changes then
			return "[sys] missing changes argument"
		end
		vim.schedule(function() apply_patch(args.name, args.changes) end)
		return "[sys] patch received and submitted for user approval"
	end

	return "[tai] Unknown tool `" .. tool .. "`"
end

return M
