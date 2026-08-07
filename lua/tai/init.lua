local M = {}

local log = require("tai.log")
local config = require("tai.config")
local ui = require("tai.ui")
local mcp = require("tai.mcp")
local tools = require("tai.tools")

function M.setup(opts)
	log.set_level(opts.log_level or log.DEBUG)

	if not config.provider then
		return
	end

	-- Initialize context module if enabled
	if config.context and config.context.enabled then
		local context = require("tai.context")
		context.setup(config.context)
	end

	-- Configure + connect MCP servers from .tai
	mcp.configure(config.mcps)
	mcp.update_tool_def(tools.defs)
	mcp.connect_all(function()
		mcp.update_tool_def()
	end)

	ui.init()
end

function M.reload(opts)
	local ok, err = config.reload()
	if not ok then
		vim.notify("tai: failed to reload config: " .. (err or ""), vim.log.levels.ERROR)
		return
	end
	mcp.configure(config.mcps)
	mcp.update_tool_def(tools.defs)
	mcp.connect_all(function()
		mcp.update_tool_def()
	end)
	ui.update_chat_name()
	ui.update_input_name()
	vim.notify("tai: config reloaded", vim.log.levels.INFO)
end

function M.toggle_chat_window()
	ui.toggle_chat_window()
end

function M.clear_history()
	ui.clear()
end

function M.chat()
	ui.open()
	ui.focus_input()
end

function M.stop()
	ui.stop()
end

return M
