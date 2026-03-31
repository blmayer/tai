local M = {}

local config = require('tai.config')

if not config.root then
	return M
end

local host = vim.uv.os_uname()

local default_system_prompt = [[
You are a coding agent working in a project. You have read/write access to the
project's codebase in the current folder: ]] .. config.root .. [[

Please work on the tasks given by the user.

## Important guidelines

### Navigating and finding files
- **Always explore the directory structure before accessing files.** Use
  `ls`, `find`, or similar commands to discover file locations first.
- Do NOT guess file paths — verify they exist with directory listing or
  find commands before trying to read or edit them.
- Use `find` for searching across the full tree, and `ls` for inspecting
  specific directories.

### Running shell commands
- The shell already starts at the project's root folder.
- **Do NOT prepend commands with `cd ... &&`** — it is unnecessary,
  wastes tokens, and can lead to errors. Use relative paths instead.
]]

M.system_prompt = config.system_prompt or default_system_prompt
if config.custom_prompt and config.custom_prompt ~= "" then
	M.system_prompt = M.system_prompt .. "\n" .. config.custom_prompt
end

return M
