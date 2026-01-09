local M = {}

local log = require("tai.log")

local function find_tai_root()
	local current = vim.fn.getcwd()
	while current ~= "/" do
		local tai_file = current .. "/.tai"
		if vim.fn.filereadable(tai_file) == 1 then
			return current
		end
		current = vim.fn.fnamemodify(current, ":h")
	end
	return nil
end

local root_path = find_tai_root()
if not root_path then
	return M
end

M.model = "devstral-medium-latest"
M.provider = "z_ai"
M.root = root_path

local file = io.open(M.root .. "/.tai", "r")
if file then
	local ok, data = pcall(vim.fn.json_decode, file:read("*a"))
	file:close()
	if not ok then
		log.error("failed to read config, using defaults")
	end
	if data and type(data) == 'table' then
		M.model = data.model or M.model
		M.provider = data.provider or M.provider
		M.options = data.options
		M.think = data.think or nil
	end
end

return M
