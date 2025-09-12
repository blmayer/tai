local M = {}

M.allowed_commands = {
	["cat"] = true,
	["echo"] = true,
	["date"] = true,
	["tail"] = true,
	["head"] = true,
	["grep"] = true,
	["cut"] = true,
	["ls"] = true,
	["wc"] = true,
	["make"] = true,
	["sort"] = true
}

M.model = "devstral-medium-latest"
M.summary_model = "ministral-8b-latest"
M.complete_model = "llama-3.3-70b-versatile"
M.skip_cache = false
M.provider = "mistral"
M.cache_dir = "~/.tai-cache/"
M.root = "~"

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

M.root = find_tai_root()
if not M.root then
	vim.notify("[tai] .tai file not found, quitting.", vim.log.levels.WARN)
	return
end

M.cache_dir = M.root .. "/.tai-cache/"

local file = io.open(M.root .. "/.tai", "r")
if not file then return end
local ok, data = pcall(vim.fn.json_decode, file:read("*a"))
file:close()
if not data then return end

M.model = data.model or M.model
M.summary_model = data.summary_model or M.summary_model
M.complete_model = data.complete_model or M.complete_model
M.provider = data.provider or M.provider
if data.allowed_commands then
	M.allowed_commands = {}

	-- Convert the list to a map for quick lookup
	for _, cmd in ipairs(data.allowed_commands) do
		M.allowed_commands[cmd] = true
	end
end
M.skip_cache = data.skip_cache or M.skip_cache

return M
