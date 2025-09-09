local M = {}
local log = require("tai.log")
local command = require("tai.command")
local project = require("tai.project")

local bufname = "tai-output"

local function ensure_buf()
	local bufnr = vim.fn.bufnr(bufname)
	if bufnr == -1 then
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, bufname)
		vim.bo[bufnr].buftype = "nofile"
		vim.bo[bufnr].bufhidden = "hide" -- keep content when hidden
		vim.bo[bufnr].swapfile = false
		vim.bo[bufnr].modifiable = true
		vim.bo[bufnr].filetype = "tai-output"
	end
	return bufnr
end

function M.toggle_output_window()
	local bufnr = ensure_buf()
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

function M.show_response(fields, filename)
	local bufnr = ensure_buf()

	local content = ""
	if fields.plan and #fields.plan > 0 then
		content = "Plan:\n\n"
		for i, p in ipairs(fields.plan) do
			content = content .. i .. ". " .. p .. "\n"
		end
		content = content .. "\n-----------------------------\n\n"
	end
	if fields.text then
		content = content .. fields.text
	end
	if fields.commands and #fields.commands > 0 then
		content = content .. "\n\nCommand requested (use :RunTaiCommand to run):\n\n"
		for _, cmd in ipairs(fields.commands) do
			content = content .. cmd .. "\n\n"
		end
		vim.api.nvim_buf_create_user_command(
			bufnr, 'RunTaiCommand',
			function() M.run_commands(fields.commands) end,
			{}
		)
	end
	if fields.patch then
		content = content .. "\n\nPatch (use :ApplyTaiPatch to apply):\n\n" .. fields.patch
		vim.schedule(function()
			local patch = fields.patch
			vim.api.nvim_buf_create_user_command(bufnr, 'ApplyTaiPatch',
				function() M.apply_patch(patch, filename) end,
				{})
		end)
	end

	local lines = vim.split(content, "\n", { trimempty = true })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Auto-open if hidden
	if vim.fn.bufwinnr(bufnr) == -1 then
		vim.cmd("vsplit")
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, bufnr)
		vim.api.nvim_win_set_width(win, 80)
	else
		-- Ensure focus on existing window
		vim.api.nvim_set_current_win(vim.fn.bufwinid(bufnr))
	end
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
	vim.bo[bufnr].filetype = 'tai-input'

	--vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {prompt or "Enter your message:"})

	vim.keymap.set('n', '<CR>', function()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local text = table.concat(lines, '\n')
		vim.api.nvim_win_close(winnr, false)
		callback(text)
	end, { buffer = bufnr })
end

function M.apply_patch(patch)
	local real = io.popen("ed -s", "w")
	real:write(patch)
	real:close()
	vim.api.nvim_command("checktime")
end

function M.run_commands(cmds)
	local output = ""

	for _, cmd in ipairs(cmds) do
		-- Check for @read file_name pattern
		if cmd:match("^@read%s+(.+)$") then
			local file = cmd:match("^@read%s+(.+)$")
			local reply = project.request_append_file(file, "I added the file requested as system prompt, continue with the task.")
			return M.show_response(reply)
		end

		if not command.validate(cmd) then
			output = "[tai] Command " .. cmd .. " is not allowed"
		end

		local out = command.run(cmd)
		if out then
			output = output .. "\n\nOutput of ```" .. cmd .. "```:\n" .. out
		else
			output = output .. "\n\n```" .. cmd .. "``` returned null"
		end
	end

	vim.schedule(function()
		vim.notify("[tai] Sending commands output", vim.log.levels.TRACE)
	end)

	local reply = project.process_request(output)
	return M.show_response(reply)
end

return M
