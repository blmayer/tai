local M = {}

local log = require("tai.log")
local ui = require("tai.ui")

function M.setup(opts)
	log.set_level(opts.log_level or log.DEBUG)
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
