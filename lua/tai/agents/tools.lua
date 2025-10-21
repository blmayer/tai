local M = {}

local log = require('tai.log')
local config = require('tai.config')

M.defs = {
	read_file = {
		type = "function",
		["function"] = {
			name = "read_file",
			description = "Reads the content of a file from the file system.",
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
			"Creates a patcher from the given changes, please separate them by file, use line numbers and show the new content.",
			parameters = {
				type = "object",
				properties = {
					changes = {
						type = "string",
						description =
						"Changes to be made. Please separate them by file, use line numbers and show the new content."
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
			description = "Runs commands in a shell and returns the output.",
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
		return "[tai] File " .. file_path .. " not found"
	end

	local content = file:read("*all")
	file:close()

	local numbered_lines = {}
	for i, line in ipairs(vim.split(content, '\n', { plain = true })) do
		table.insert(numbered_lines, string.format("%d: %s", i, line))
	end
	local numbered_content = table.concat(numbered_lines, "\n")

	log.debug("read_file output: " .. numbered_content)
	return "[tai] Content of " .. file_path .. ":\n" .. numbered_content .. "\n"
end

local function validate_command(cmd)
	local parts = vim.split(cmd, "%s+")
	if #parts == 0 then return false end

	local base = parts[1]:match("^([^/]+)$")
	if not base then
		return false
	end

	local ok = false
	for _, c in ipairs(config.allowed_commands) do
		if c == base then
			ok = true
			break
		end
	end

	if not ok then
		return false
	end

	for _, arg in ipairs(parts) do
		if arg:sub(1, 1) == "-" then
			goto continue
		end
		if arg:sub(1, 1) == "/" then
			return false
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

	if not validate_command(cmd) then
		log.debug("command is not allowed")
		return "[tai] Command " .. cmd .. " is not allowed"
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
		output = "[tai] Output of ```" .. cmd .. "```:\n" .. output
	else
		output = "[tai] ```" .. cmd .. "``` returned null"
	end
	log.debug("command output: " .. output)

	return output
end

function M.run(cmds)
	log.debug("Running tool calls")
	local output = ""

	for _, cmd in ipairs(cmds) do
		local tool = cmd["function"]["name"]
		local args = cmd["function"].arguments

		if tool == "read_file" then
			output = output .. read_file(args.file_path)
		elseif tool == "run" then
			output = output .. run_command(args.command)
		end
	end

	return output
end

return M
