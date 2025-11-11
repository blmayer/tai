local M = {}

local log = require("tai.log")
local ui = require("tai.ui")
local project = require("tai.project")

function M.setup(opts)
	log.set_level(log.DEBUG)
	project.init()
end

function M.toggle_chat_window()
	ui.toggle_output_window()
end

function M.chat()
	ui.input(function(input)
		if not input or input == "" then return end
		log.debug("Received user input: " .. input)

		vim.schedule(function()
			ui.open()
			ui.append_to_buffer("--------------------------\n> " .. input .. "\n")
		end)

		project.chat(input)
	end)
end

function M.reset()
	project.clear_history()
end

function M.prompt_full_file()
	local path = vim.fn.expand("%")
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	local location = string.format("line %d, column %d", row, col)

	ui.input(function(input)
		if not input or input == "" then return end

		local prompt = string.format("I'm edditing %s with cursor at %s. Q: %s", path, location, input)

		local result = project.request_append_file(path, prompt)
		ui.show_response(result)
	end)
end

function M.continue()
	local path = vim.fn.expand("%")
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	local location = string.format("line %d, column %d", row, col)

	local prompt = string.format(
	"Cursor is at %s, user asked you to complete the code next to the cursor, return the **ONLY** the correct continuation.",
		location)

	local result = project.request_append_file(path, prompt)
	ui.insert_response(result.text)
end

function M.operator_send(type)
	local old_reg = vim.fn.getreg('"')
	vim.cmd('normal! gv"zy')
	local text = vim.fn.getreg("z")
	vim.fn.setreg('"', old_reg)

	local result = project.process_request(text)
	ui.show_response(result)
end

function M.operator_send_with_prompt(type)
	local old_reg = vim.fn.getreg('"')
	vim.cmd('normal! gv"zy')
	local text = vim.fn.getreg("z")
	vim.fn.setreg('"', old_reg)

	ui.input(function(input)
		local full = input .. "\n\nSelected code:\n" .. text
		local result = project.process_request(full)
		ui.show_response(result)
	end)
end

function M.complete()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()
	local result = project.complete(line)
	ui.insert_response(result)
end

function M.replace_visual()
	ui.input(function(input)
		local payload = string.format("I'm replacing text, your text response will the pasted as is. Q:\n", input)
		local result = project.process_request(payload)
		ui.replace_visual_selection(result)
	end)
end

return M
