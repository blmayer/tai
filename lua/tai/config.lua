local M = {}

local log = require("tai.log")

M.allowed_commands = {
	"cat",
	"cut",
	"date",
	"echo",
	"find",
	"grep",
	"head",
	"ls",
	"make",
	"sort",
	"tail",
	"wc"
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
	if not ok then
		log.error("failed to read config, using defaults")
	end
	if data and type(data) == 'table' then
		M.model = data.model or M.model
		M.summary_model = data.summary_model or M.summary_model
		M.complete_model = data.complete_model or M.complete_model
		M.provider = data.provider or M.provider
		M.planner = {
			model = data.planner.model,
			options = data.planner.options,
			tools = data.planner.tools,
			think = data.planner.think or nil
		}
		M.coder = {
			model = data.coder.model,
			options = data.coder.options,
			tools = data.coder.tools,
			think = data.coder.think or nil
		}
		M.patcher = {
			model = data.patcher.model,
			options = data.patcher.options,
			tools = data.patcher.tools,
			think = data.patcher.think or nil
		}
		M.writer = {
			model = data.writer.model,
			options = data.writer.options,
			tools = data.writer.tools,
			think = data.writer.think or nil
		}
		M.all_rounder = {
			model = data.all_rounder.model,
			options = data.all_rounder.options,
			tools = data.all_rounder.tools,
			think = data.all_rounder.think or nil
		}
		if data.allowed_commands then
			M.allowed_commands = data.allowed_commands
		end
		M.skip_cache = data.skip_cache or M.skip_cache
	end
end

return M
