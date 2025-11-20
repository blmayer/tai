local M = {}
local log = require("tai.log")

local bufname = "tai-chat"
local input_bufname = "tai-chat-input"

local function ensure_input_buf()
	local bufnr = vim.fn.bufnr(input_bufname)
	if bufnr == -1 then
		bufnr = vim.api.nvim_create_buf(true, false) -- scratch buffer, not listed
		vim.api.nvim_buf_set_name(bufnr, input_bufname)
		vim.bo[bufnr].buftype = 'nofile'
		vim.bo[bufnr].bufhidden = 'wipe'
		vim.bo[bufnr].swapfile = false
		vim.bo[bufnr].filetype = 'text'
		vim.bo[bufnr].modifiable = true

		-- Keybindings for the input buffer
		vim.keymap.set('n', '<CR>', function() M.send_current_input() end, { buffer = bufnr })
	end
	return bufnr
end

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
M.input_buffer_nr = ensure_input_buf()

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
M.input_buffer_nr = ensure_input_buf()

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

function M.toggle_output_window(callback)
	local bufnr = M.buffer_nr
	local winid = vim.fn.bufwinnr(bufnr)
	local input_winid = vim.fn.bufwinnr(M.input_buffer_nr)
	if winid ~= -1 then
		-- Close the window
		vim.api.nvim_win_close(winid, false)
		if input_winid ~= -1 then
			vim.api.nvim_win_close(input_winid, false)
		end
	else
		M.open(callback)
	end
end

function M.open(callback)
	vim.schedule(function()
		if vim.fn.bufwinnr(M.buffer_nr) == -1 then
			vim.cmd("vsplit")
			local win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, M.buffer_nr)
			vim.api.nvim_win_set_width(win, 80)

			-- Open input buffer in horizontal split below the output
			vim.cmd("below split") -- horizontal split below
			local input_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input_win, M.input_buffer_nr)
			vim.api.nvim_win_set_height(input_win, 6) -- 6 lines for input

			vim.keymap.set('n', '<CR>', function()
				local input = table.concat(vim.api.nvim_buf_get_lines(M.input_buffer_nr, 0, -1, false), '\n')
				callback(input)
			end, { buffer = M.input_buffer_nr })
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
							    hunk.operation .. " " .. hunk.lines .. ":\n" .. hunk.content
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

-- Prompt user for multi-line input with Shift+Enter support
function M.input(callback)
	-- Focus input window and enter insert mode
	vim.api.nvim_get_current_win()
	vim.cmd("startinsert")

	-- local bufnr = vim.api.nvim_create_buf(false, true)
	-- local width = math.min(80, vim.o.columns - 10)
	-- local height = math.min(10, vim.o.lines - 10)

	-- local winnr = vim.api.nvim_open_win(bufnr, true, {
	-- 	relative = 'editor',
	-- 	width = width,
	-- 	height = height,
	-- 	col = (vim.o.columns - width) / 2,
	-- 	row = (vim.o.lines - height) / 2,
	-- 	style = 'minimal',
	-- 	border = 'rounded'
	-- })

	-- vim.bo[bufnr].buftype = 'nofile'
	-- vim.bo[bufnr].bufhidden = 'wipe'
	-- vim.bo[bufnr].swapfile = false
	-- vim.bo[bufnr].filetype = 'text'

	-- vim.keymap.set('n', '<CR>', function()
	-- 	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	-- 	local text = table.concat(lines, '\n')
	-- 	vim.api.nvim_win_close(winnr, false)
	-- 	callback(text)
	-- end, { buffer = bufnr })
end

return M
