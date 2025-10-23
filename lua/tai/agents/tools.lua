local M = {}

local log = require('tai.log')
local config = require('tai.config')

M.defs = {
	read_file = {
		type = "function",
		["function"] = {
			name = "read_file",
			description = "Reads the content of a file from the file system. And returns the content with numberred lines.",
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
			description = "Creates a patch from the given changes, please separate them by file and operation, use line numbers and show the new content. This will ask for user approval.",
			parameters = {
				type = "object",
				properties = {
					changes = {
						type = "array",
						description = "List of changes to be made. Each change is applied independently on the original file, i.e. the order matters, but line numbers are not updated.",
						items = {
							type = "object",
							properties = {
								file = {
									type = "string",
									description = "File name of this change, relative to the current folder (don't start with /)."
								},
								operation = {
									type = "string",
									description = "Operation of this change.",
									enum = { "add" , "change", "delete" }
								},
								lines = {
									type = "string",
									description = "Range of lines that the operation is on, starts at 1. Formats: \\d: single line; \\d-\\d: inclusive range; $: last line. Note: to add before the first line use 0.",
								},
								content = {
									type = "string",
									description = "New content. Not used for delete operation.",
								},
							},
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
			description = "Runs commands in a shell in the current folder and returns the output. Use relative paths (don't start with /).",
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

	local file = io.open(file_path, "r")
	if not file then
		return "[tai] File `" .. file_path .. "` not found"
	end

	local content = file:read("*all")
	file:close()

	local numbered_lines = {}
	for i, line in ipairs(vim.split(content, '\n', { plain = true })) do
		table.insert(numbered_lines, string.format("%d: %s", i, line))
	end
	local numbered_content = table.concat(numbered_lines, "\n")

	log.debug("read_file output: " .. numbered_content)
	return "[sys] Content of `" .. file_path .. "`:\n" .. numbered_content .. "\n"
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
		return "Command not allowed."
	end

	for _, arg in ipairs(parts) do
		if arg:sub(1, 1) == "-" then
			goto continue
		end
		if arg:sub(1, 1) == "/" then
			return "Paths cannot start from root (/). Use relative."
		end
		if arg:match("%.%.") then
			return false
		end
		if arg:match("[*?]") then
			return false
		end
		::continue::
	end

	return true
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

	if output then
		output = "[sys] Output of `" .. cmd .. "`:\n" .. output
	else
		output = "[sys] `" .. cmd .. "` returned null"
	end
	log.debug("command output: " .. output)

	return output
end

local function apply_patch(changes)
	log.debug("Running patch with " .. #changes .. " changes")

	-- local real = io.popen("ed -s 2>&1", "w")
	-- if not real then
	-- 	vim.notify("[tai] failed to apply patch: popen is null", vim.log.levels.ERROR)
	-- 	return
	-- end

	-- real:write(changes)
	-- local output = real:read("*all")
	-- real:close()

	-- if output then
	-- 	log.debug("Patch application output: " .. output)
	-- end
	-- vim.api.nvim_command("checktime")
end

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
		return apply_patch(args.changes)
	end

	return "[tai] Unknown tool `" .. tool .. "`"
end

return M
