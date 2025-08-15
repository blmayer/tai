local M = {}

local ui = require("tai.ui")
local project = require("tai.project")

function M.setup(opts)
	project.init()
end

function M.toggle_chat_window()
	ui.toggle_output_window()
end

function M.prompt_input()
	ui.input(function(input)
		if not input or input == "" then return end
		local result = project.process_request(input)
		ui.show_response(result)
	end)
end

function M.prompt_full_file()
	local path = vim.fn.expand("%")
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()

	local location = string.format("line %d, column %d", row, col)

	ui.input(function(input)
		if not input or input == "" then return end

		local prompt = string.format("I'm edditing %s with cursor at %s, the prompt is:\n%s", path, location,
			input)

		local result = project.request_file_prompt(path, prompt)
		ui.show_response(result)
	end)
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

function M.insert_response()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()

	local filename = vim.fn.expand("%")

	local location = string.format("line %d, column %d", row, col)
	local payload = string.format(
		"I'm edditing %s with cursor at %s, the current line content is (inside backticks): ```%s```. Please continue that line, send **ONLY** the new text, don't send commentary or instructions. Your response is appended to the end of the cursor.",
		filename, location, line)

	local result = project.process_request(payload)
	ui.insert_response(result)
end

function M.replace_visual()
	ui.input(function(input)
		local payload = string.format("I'm replacing text, your response will the pasted as is. Prompt:\n", input)
		local result = project.process_request(payload)
		ui.replace_visual_selection(result)
	end)
end

return M
