local M = {}
local log = require("tai.log")

local bufname = "tai-chat"
local input_bufname = "tai-chat-input"

local chat_win
local input_win
local callback

M.input_buffer_nr = vim.api.nvim_create_buf(true, false) -- scratch buffer, not listed
vim.api.nvim_buf_set_name(M.input_buffer_nr, input_bufname)
vim.bo[M.input_buffer_nr].buftype = 'nofile'
vim.bo[M.input_buffer_nr].bufhidden = 'hide'
vim.bo[M.input_buffer_nr].swapfile = false
vim.bo[M.input_buffer_nr].filetype = 'text'
vim.bo[M.input_buffer_nr].modifiable = true

M.buffer_nr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(M.buffer_nr, bufname)
vim.bo[M.buffer_nr].buftype = "nofile"
vim.bo[M.buffer_nr].bufhidden = "hide" -- keep content when hidden
vim.bo[M.buffer_nr].swapfile = false
vim.bo[M.buffer_nr].modifiable = true
vim.bo[M.buffer_nr].filetype = "text"

-- Autoclose TAI UI buffers on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("TaiUiCleanup", { clear = true }),
	callback = function()
		if vim.api.nvim_buf_is_valid(M.buffer_nr) then
			vim.api.nvim_buf_delete(M.buffer_nr, { force = true })
		end
		if vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
			vim.api.nvim_buf_delete(M.input_buffer_nr, { force = true })
		end
	end,
})

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

function M.scroll_down()
	vim.schedule(function()
		local original_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(chat_win)
		vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(M.buffer_nr), 0 })
		vim.cmd("normal! zt")
		vim.api.nvim_set_current_win(original_win)
	end)
end

function M.add_sep()
	local width = vim.api.nvim_win_get_width(chat_win)
	local result = ""
	for i = 1, width do
		result = result .. "_"
	end
	M.append_to_buffer(result .. "\n")
end

function M.set_chat_callback(cb)
	callback = cb
end

local function send_input()
	vim.schedule(function()
		M.scroll_down()
		local input = table.concat(vim.api.nvim_buf_get_lines(M.input_buffer_nr, 0, -1, false),
			'\n')
		vim.api.nvim_buf_set_lines(M.input_buffer_nr, 0, -1, false, {})
		callback(input)
	end)
end

function M.toggle_chat_window()
	local winid = vim.fn.bufwinnr(M.buffer_nr)
	local input_winid = vim.fn.bufwinnr(M.input_buffer_nr)
	if winid ~= -1 then
		-- Close the window
		vim.api.nvim_win_close(chat_win, false)
		if input_winid ~= -1 then
			vim.api.nvim_win_close(input_win, false)
		end
	else
		M.open()
	end
end

function M.focus_input()
	vim.schedule(function()
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("startinsert")
	end)
end

function M.open()
	vim.schedule(function()
		local chat_window_nr = vim.fn.bufwinnr(M.buffer_nr)
		if chat_window_nr == -1 then
			vim.cmd("vsplit")
			chat_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(chat_win, M.buffer_nr)
			vim.api.nvim_win_set_width(chat_win, 80)
			vim.api.nvim_win_set_config(chat_win, { fixed = true })

			-- Open input buffer in horizontal split below the output
			vim.cmd("below split") -- horizontal split below
			input_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input_win, M.input_buffer_nr)
			vim.api.nvim_win_set_height(input_win, 8) -- 8 lines for input

			vim.keymap.set('n', '<CR>', send_input, { buffer = M.input_buffer_nr })
			vim.keymap.set('i', '<S-CR>', send_input, { buffer = M.input_buffer_nr })
		end
	end)
end

function M.show_response(fields)
	log.debug("Showing response")
	M.open()

	local content = ""
	if fields.error then
		content = content .. "[tai] " .. fields.error .. "\n"
		M.append_to_buffer(content)
		return
	end
	if fields.content and fields.content ~= "" then
		content = content .. fields.content .. "\n"
	end

	if fields.tool_calls then
		for _, call in ipairs(fields.tool_calls) do
			local args = call["function"].arguments

			if call["function"].name == "run" then
				content = content .. "[tai] Running " .. args.command .. "\n"
			elseif call["function"].name == "read_file" then
				content = content .. "[tai] Reading " .. args.file_path .. "\n"
			elseif call["function"].name == "patch" then
				content = content .. "[tai] Patching " .. #args.changes .. " file(s):\n"
				for _, change in ipairs(args.changes) do
					content = content .. "\t" .. change.file .. ":\n"
					for _, hunk in ipairs(change.hunks) do
						if hunk.operation == "delete" then
							content = content .. "\tdelete " .. hunk.lines .. "\n"
						else
							content = content ..
							    "\t" ..
							    hunk.operation ..
							    " " .. hunk.lines .. ":\n" .. hunk.content .. "\n"
						end
					end
				end
			end
		end
	end
	if not fields.tool_calls and not fields.content then
		content = content .. "[tai] Received empty reply."
	end

	M.append_to_buffer(content)
end

function M.clear()
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, {})
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

return M
