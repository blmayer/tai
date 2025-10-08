local M = {}
local log = require("tai.log")

local bufname = "tai-chat"

local function ensure_buf()
	local bufnr = vim.fn.bufnr(bufname)
	if bufnr == -1 then
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, bufname)
		vim.bo[bufnr].buftype = "nofile"
		vim.bo[bufnr].bufhidden = "hide" -- keep content when hidden
		vim.bo[bufnr].swapfile = false
		vim.bo[bufnr].modifiable = true
		vim.bo[bufnr].filetype = "text"
	end
	return bufnr
end

M.buffer_nr = ensure_buf()

function M.append_to_buffer(content)
	local new_lines = vim.split(content, "\n")
	vim.schedule(function()
		local current_lines_count = vim.api.nvim_buf_line_count(M.buffer_nr)
		if current_lines_count == 1 and vim.api.nvim_buf_get_lines(M.buffer_nr, 0, 1, false)[1] == "" then
			-- If buffer is essentially empty (one empty line), replace it
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 1, false, new_lines)
		else
			-- Append to existing content
			vim.api.nvim_buf_set_lines(M.buffer_nr, current_lines_count, current_lines_count, false,
				new_lines)
		end
	end)
end

function M.toggle_output_window()
	local bufnr = M.buffer_nr
	local winid = vim.fn.bufwinnr(bufnr)
	if winid ~= -1 then
		-- Close the window
		vim.cmd(winid .. "close")
	else
		-- Open in vertical split
		vim.cmd("vsplit")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, bufnr)
		vim.api.nvim_win_set_width(win, 80)
	end
end

function M.open()
	vim.schedule(function()
		if vim.fn.bufwinnr(M.buffer_nr) == -1 then
			vim.cmd("vsplit")
			local win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, M.buffer_nr)
			vim.api.nvim_win_set_width(win, 80)
		end
	end)
end

function M.show_response(fields)
	log.debug("Showing response")

	local content = "\n----------------------------\n"
	if fields.error then
		content = content .. fields.error
	end
	if fields.plan and #fields.plan > 0 then
		content = "--- Plan ------------------------\n\n"
		for i, p in ipairs(fields.plan) do
			content = content .. i .. ". " .. p .. "\n"
		end
		content = content .. "___________________________\n\n"
	end
	if fields.text then
		content = content .. fields.text
	end
	if fields.commands and #fields.commands > 0 then
		content = content .. "\n\nCommand requested (use :RunTaiCommand to run):\n\n"
		for _, cmd in ipairs(fields.commands) do
			content = content .. cmd .. "\n\n"
		end
	end
	if fields.patch then
		content = content .. "\n\nPatch (use :ApplyTaiPatch to apply):\n\n" .. fields.patch
	end
	content = content .. "\n\n"

	M.append_to_buffer(content)
	M.open()
end

function M.show_tool_calls(calls)
	log.debug("Showing tool calls")

	local content = "\n--- tool calls ---------------------\n"
	for _, call in ipairs(calls) do
		content = content .. "> Sending output of " .. call["function"].name .. "\n"
	end
	content = content .. "____________________________________\n"

	M.append_to_buffer(content)
	M.open()
end

-- Insert the content at the cursor (insert mode)
function M.insert_response(content)
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local lines = vim.split(content, "\n", { plain = true })
	local bufnr = vim.api.nvim_get_current_buf()

	local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before = current_line:sub(1, col)
	local after = current_line:sub(col + 1)

	lines[1] = before .. lines[1]
	lines[#lines] = lines[#lines] .. after

	local new_col = #lines[#lines] - #after
	vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, lines)
	vim.api.nvim_win_set_cursor(0, { row + #lines - 1, new_col })
end

-- Replace selected text (visual mode)
function M.replace_visual_selection(content)
	local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
	local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))
	local bufnr = vim.api.nvim_get_current_buf()

	if csrow > cerow or (csrow == cerow and cscol > cecol) then
		csrow, cerow = cerow, csrow
		cscol, cecol = cecol, cscol
	end

	local replacement = vim.split(content, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, csrow - 1, cerow, false, replacement)
end

-- Prompt user for multi-line input with Shift+Enter support
function M.input(callback)
	local bufnr = vim.api.nvim_create_buf(false, true)
	local width = math.min(80, vim.o.columns - 10)
	local height = math.min(10, vim.o.lines - 10)

	local winnr = vim.api.nvim_open_win(bufnr, true, {
		relative = 'editor',
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = 'minimal',
		border = 'rounded'
	})

	vim.bo[bufnr].buftype = 'nofile'
	vim.bo[bufnr].bufhidden = 'wipe'
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = 'text'

	vim.keymap.set('n', '<CR>', function()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local text = table.concat(lines, '\n')
		vim.api.nvim_win_close(winnr, false)
		callback(text)
	end, { buffer = bufnr })
end

return M
