local M = {}

local ui = require("tai.ui")
local project = require("tai.project")
local chat = require("tai.chat")

function M.setup(opts)
	require("tai.project").init_project_prompt()
end

function M.prompt_input()
	ui.input("Tai Input: ", function(input)
		if input and input ~= "" then
			local result = chat.send_chat(input)
			ui.show_output_in_vsplit(result)
		end
	end)
end

function M.prompt_full_file()
	local path = vim.fn.expand("%:p")

	ui.input("Tai Input: ", function(user_input)
		if not user_input or user_input == "" then return end
		local result = project.request_file_prompt(path, user_input)
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

	ui.input("Tai Input: ", function(prompt)
		local full = prompt .. "\n\n" .. text
		local result = project.process_request(full)
		ui.show_response(result)
	end)
end

function M.insert_response()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local line = vim.api.nvim_get_current_line()

	local filename = vim.fn.expand("%:p")

	local location = string.format("line %d, column %d", row, col)
	local payload = string.format(
		"I'm edditing %s with cursor at %s, the current line content is (inside backticks): ```%s```. Please continue that line, send **ONLY** the new text, don't send commentary or instructions. Your response is appended to the end of the cursor.",
		filename, location, line)

	local result = project.process_request(payload)
	print(result.text)
	ui.insert_response(result)
end

function M.replace_visual()
	ui.input("Tai Replace: ", function(input)
		local result = project.process_request(input)
		ui.replace_visual_selection(result)
	end)
end

return M
