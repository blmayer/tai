local M = {}
local log = require("tai.log")

M.root = vim.fn.getcwd()
while vim.fn.filereadable(M.root .. "/.tai") == 0 do
	M.root = vim.fn.fnamemodify(M.root, ":h")
end

log.debug("Root is " .. M.root)

if not M.root then
	return M
end

function M.reload()
	if not M.root then
		return false, "no tai root found"
	end

	local f = io.open(M.root .. "/.tai", "r")
	if not f then
		return false, "failed to open .tai"
	end

	local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
	f:close()
	if not ok or type(data) ~= "table" then
		return false, "failed to parse .tai"
	end

	M.model = data.model or M.model
	M.provider = data.provider or M.provider
	M.use_tools = data.use_tools
	if M.use_tools == nil then
		M.use_tools = true
	end
	M.options = data.options
	M.think = data.think or nil

	return true
end

M.reload()

return M
