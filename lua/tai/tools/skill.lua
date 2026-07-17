--- tai/tools/skill.lua — Implementation of the `skill` tool actions.

local M = {}
local skills = require("tai.skills")

--- Run a skill tool call.
--- @param args table  {action, id?}
--- @return string  result text
function M.run(args)
	local action = args.action
	if action == "list" then
		return skills.list()
	elseif action == "status" then
		if not args.id or args.id == "" then
			return "Error: 'id' is required for 'status'."
		end
		return skills.status(args.id)
	elseif action == "load" then
		if not args.id or args.id == "" then
			return "Error: 'id' is required for 'load'."
		end
		return skills.load(args.id)
	elseif action == "unload" then
		if not args.id or args.id == "" then
			return "Error: 'id' is required for 'unload'."
		end
		return skills.unload(args.id)
	end
	return "Error: unknown action '" .. tostring(action) .. "'. Valid: list, status, load, unload."
end

return M
