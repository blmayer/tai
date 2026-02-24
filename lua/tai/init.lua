local M = {}

local log = require("tai.log")
local config = require("tai.config")
local ui = require("tai.ui")

function M.setup(opts)
	log.set_level(opts.log_level or log.DEBUG)
end

function M.reload(opts)
	local ok, err = config.reload()
	if not ok then
		vim.notify("tai: failed to reload config: " .. (err or ""), vim.log.levels.ERROR)
		return
	end
	ui.update_chat_name()
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

return M
