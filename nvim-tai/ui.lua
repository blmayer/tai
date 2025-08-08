local M = {}

function M.show_response(fields)
	local bufname = "tai-output"

	local bufnr = vim.fn.bufnr(bufname)
	if bufnr == -1 then
		vim.cmd("vnew")
		local new_win = vim.api.nvim_get_current_win()
		bufnr = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_set_width(new_win, 80) -- this is THE number

		-- Set buffer options to make it a scratch window
		vim.bo[bufnr].buftype = "nofile"
		vim.bo[bufnr].bufhidden = "wipe"
		vim.bo[bufnr].swapfile = false
		vim.bo[bufnr].modifiable = true
		vim.bo[bufnr].filetype = "tai-output"
		vim.api.nvim_buf_set_name(bufnr, bufname)
	end

	local content = ""
	if fields.plan then
		content = "Plan:\n\n" .. fields.plan .. "\n\n-----------------------------\n\n"
	end

	if fields.text then
		content = content .. fields.text
	end
	if fields.commands then
		content = content .. "\n\nCommands requested:\n\n" .. fields.commands
	end

	if fields.patch then
		content = content .. "\n\nPatch (use :ApplyTaiPatch to apply):\n\n" .. fields.patch
		vim.schedule(function()
			local patch = fields.patch
			vim.api.nvim_buf_create_user_command(bufnr, 'ApplyTaiPatch', function() M.apply_patch(patch) end,
				{})
		end)
	end

	local lines = vim.split(content, "\n", { trimempty = true })

	-- Insert content
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Insert the content at the cursor (insert mode)
function M.insert_response(content)
	if not content.text then
		return
	end

	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local lines = vim.split(content.text, "\n", { plain = true })
	local bufnr = vim.api.nvim_get_current_buf()

	local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before = current_line:sub(1, col)
	local after = current_line:sub(col + 1)

	lines[1] = before .. lines[1]
	lines[#lines] = lines[#lines] .. after

	vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, lines)
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
	vim.bo[bufnr].filetype = 'tai-input'

	--vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {prompt or "Enter your message:"})

	vim.keymap.set('n', '<CR>', function()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local text = table.concat(lines, '\n')
		vim.api.nvim_win_close(winnr, false)
		vim.schedule(function()
			vim.notify("[tai] Got prompt", vim.log.levels.TRACE)
		end)
		callback(text)
	end, { buffer = bufnr })
end

function M.apply_patch(patch)
	local f = io.popen("patch -p0", "w")
	f:write(patch)
	f:close()
	vim.api.nvim_command("checktime")
end

return M
