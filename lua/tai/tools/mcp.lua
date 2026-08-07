--- tai/tools/mcp.lua — Implementation of the `mcp` tool actions.

local M = {}
local mcp = require("tai.mcp")

--- Run an mcp tool call (sync, or async when on_done is provided for connect/call).
--- @param args table  {action, server?, tool?, arguments?}
--- @param on_done function|nil
--- @return string|nil
function M.run(args, on_done)
	return mcp.run(args, on_done)
end

return M
