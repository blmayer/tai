-- Tai Neovim Plugin Autoload
-- This file is loaded automatically by Neovim on startup

local tai = require("tai")

-- Setup the plugin with default/user config
tai.setup({})

-- Register global functions for operatorfunc mappings (if needed)
-- These can be used with vim.keymap.set for operator-pending mode
_G.tai_operator_send = function(type)
	vim.cmd('set operatorfunc=v:lua.tai_operator_send')
	vim.api.nvim_feedkeys("g@", "n", false)
end

_G.tai_operator_send_with_prompt = function(type)
	vim.cmd('set operatorfunc=v:lua.tai_operator_send_with_prompt')
	vim.api.nvim_feedkeys("g@", "n", false)
end

-- Register vim commands
vim.api.nvim_create_user_command("Tai", function(args)
	if args.args == "chat" then
		tai.chat()
	elseif args.args == "toggle" then
		tai.toggle_chat_window()
	elseif args.args == "reload" then
		tai.reload()
	elseif args.args == "clear" then
		tai.clear_history()
	else
		vim.notify("Tai: Unknown command: " .. args.args, vim.log.levels.WARN)
	end
end, {
	nargs = 1,
	complete = function(_, _, _)
		return { "chat", "toggle", "reload", "clear" }
	end,
})
