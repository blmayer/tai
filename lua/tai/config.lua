local M = {}

M.model = "moonshotai/kimi-k2-instruct"
M.summary_model = "meta-llama/llama-4-scout-17b-16e-instruct"
M.skip_cache = false

function M.load(path)
	local file = io.open(path, "r")
	if not file then return end
	local ok, data = pcall(vim.fn.json_decode, file:read("*a"))
	file:close()
	if not data then return end
	
	M.model = data.model or M.model
	M.summary_model = data.summary_model or M.summary_model
	M.skip_cache = data.skip_cache or M.skip_cache
	vim.notify("[tai] Config loaded.", vim.log.levels.INFO)
end

return M
