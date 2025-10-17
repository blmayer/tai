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
						"The pipeline to be interpreted by the shell in the user's machine, usually bash. These are the user approved programs: " .. table.concat(config.allowed_commands, ", ")
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

	local pre = "You also can use the following tool calls:\n"
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

function M.run(cmds)
	log.debug("Running tools")
	local output = ""

	for _, cmd in ipairs(cmds) do
		log.debug("Running command `" .. cmd["function"]["name"] .. "`")
		local args = cmd["function"].arguments
		local file = io.open(args.file_path, "r")
		if file then
			local content = file:read("*all")
			file:close()

			local numbered_lines = {}
			for i, line in ipairs(vim.split(content, '\n', { plain = true })) do
				table.insert(numbered_lines, string.format("%d: %s", i, line))
			end
			local numbered_content = table.concat(numbered_lines, "\n")
			output = output .. "\n\n[tai] Content of " .. args.file_path .. ":\n" .. numbered_content .. "\n"
		else
			output = output .. "\n\n[tai] File " .. args.file_path .. " not found"
		end
	end

	return output
end

return M
