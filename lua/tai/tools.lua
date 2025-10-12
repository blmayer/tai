local M = {}

local log = require('tai.log')

function M.run(cmds)
	log.debug("Running tools")
	local output = ""

	for _, cmd in ipairs(cmds) do
		log.debug("Running command `" .. cmd["function"]["name"] .. "`")
		local args = vim.json.decode(cmd["function"].arguments)
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
