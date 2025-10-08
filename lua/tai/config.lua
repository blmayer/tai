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
M.summary_model = "ministral-8b-latest"
M.complete_model = "llama-3.3-70b-versatile"
M.skip_cache = false
M.provider = "mistral"
M.root = root_path
M.cache_dir = M.root .. "/.tai-cache/"

local file = io.open(M.root .. "/.tai", "r")
if file then
	local ok, data = pcall(vim.fn.json_decode, file:read("*a"))
	file:close()
	if ok and data and type(data) == 'table' then
		M.model = data.model or M.model
		M.summary_model = data.summary_model or M.summary_model
		M.complete_model = data.complete_model or M.complete_model
		M.provider = data.provider or M.provider
		if M.provider == "local" then
			M.planner_model = data.planner_model
			M.coder_model = data.coder_model
			M.patcher_model = data.patcher_model
			M.writer_model = data.writer_model
		end
		if data.allowed_commands then
			M.allowed_commands = {}
			-- Convert the list to a map for quick lookup
			for _, cmd in ipairs(data.allowed_commands) do
				M.allowed_commands[cmd] = true
			end
		end
		M.skip_cache = data.skip_cache or M.skip_cache
	end
end

return M
