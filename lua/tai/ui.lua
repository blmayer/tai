local M = {}
local log = require("tai.log")
local tai = require("tai.agent")
local tools = require("tai.tools")
local config = require("tai.config")

local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

local chat_win
local input_win

function M.update_chat_name()
	local name = bufname_prefix
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s)", bufname_prefix, config.provider, config.model)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

local function update_token_display(token_count)
	local name = input_bufname
	if token_count then
		name = string.format("%s (ctx: %u)", input_bufname, token_count)
	end
	if M.input_buffer_nr and vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.input_buffer_nr, name)
	end
end

M.input_buffer_nr = vim.api.nvim_create_buf(true, false) -- scratch buffer, not listed
vim.api.nvim_buf_set_name(M.input_buffer_nr, input_bufname)
vim.bo[M.input_buffer_nr].buftype = "nofile"
vim.bo[M.input_buffer_nr].bufhidden = "hide"
vim.bo[M.input_buffer_nr].swapfile = false
vim.bo[M.input_buffer_nr].filetype = "text"
vim.bo[M.input_buffer_nr].modifiable = true

M.buffer_nr = vim.api.nvim_create_buf(false, true)
M.update_chat_name()
vim.bo[M.buffer_nr].buftype = "nofile"
vim.bo[M.buffer_nr].bufhidden = "hide" -- keep content when hidden
vim.bo[M.buffer_nr].swapfile = false
vim.bo[M.buffer_nr].modifiable = true
vim.bo[M.buffer_nr].filetype = "text"

-- When typing fold end marker in the chat buffer, refresh/close fold immediately.
vim.keymap.set("i", "}", function()
	if vim.wo.foldmethod ~= "marker" then
		return "}"
	end

	local line = vim.fn.getline(".")
	local c = vim.fn.col(".")
	local new_line = line:sub(1, c - 1) .. "}" .. line:sub(c)

	if new_line:match("}}}%s*$") then
		local tc = vim.api.nvim_replace_termcodes
		return "}" .. tc("<C-o>zx<C-o>zc", true, false, true)
	end
	return "}"
end, { buffer = M.buffer_nr, expr = true, noremap = true })

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

	local function do_append()
		local current_lines_count = vim.api.nvim_buf_line_count(M.buffer_nr)
		if current_lines_count == 1 and vim.api.nvim_buf_get_lines(M.buffer_nr, 0, 1, false)[1] == "" then
			-- If buffer is essentially empty (one empty line), replace it
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 1, false, new_lines)
		else
			-- Append to existing content
			vim.api.nvim_buf_set_lines(M.buffer_nr, current_lines_count, current_lines_count, false,
				new_lines)
		end
	end

	if vim.in_fast_event() then
		vim.schedule(do_append)
	else
		do_append()
	end
end

local function scroll_down()
	vim.schedule(function()
		if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
			return
		end
		local original_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(chat_win)
		vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(M.buffer_nr), 0 })
		vim.cmd("normal! zt")
		vim.api.nvim_set_current_win(original_win)
	end)
end

local function add_sep()
	local width = vim.api.nvim_win_get_width(chat_win)
	local result = ""
	for _ = 1, width do
		result = result .. "_"
	end
	M.append_to_buffer(result .. "\n")
end

local function refresh_and_close_folds()
	if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
		return
	end

	vim.api.nvim_win_call(chat_win, function()
		pcall(vim.cmd, "silent! normal! zx")
		pcall(vim.cmd, "silent! normal! zM")
	end)
end

local function run_tools(tool_calls)
	local results = {}
	for _, call in ipairs(tool_calls or {}) do
		local name = call["function"].name
		local args = call["function"].arguments

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}

		if name == "shell" then
			if not args.command then
				M.append_to_buffer("{{{ Running command failed: no command field.\n}}}")
				res.content = "[sys] missing command field"
				goto continue
			end

			log.debug("Asking for confirmation")
			local input = vim.fn.confirm("Run " .. args.command .. "?", "&Y\n&n\n&s (stop)", 1)
			if input == 1 then
				log.debug("Confirmed")
				M.append_to_buffer("{{{ Running: " .. args.command .. "\n")
				local out = tools.run_command(args.command)
				M.append_to_buffer((out or "") .. "\n")
				M.append_to_buffer("}}}")
				res.content = out
			elseif input == 2 then
				log.debug("Declined")
				local comment = vim.fn.input("Comment (optional): ")
				M.append_to_buffer("{{{ Declined " .. args.command .. "\n")
				if comment and comment ~= "" then
					res.content = "[sys] User declined running this command. Comment: " .. comment
					M.append_to_buffer("Comment: " .. comment .. "\n")
				else
					res.content = "[sys] User declined running this command"
				end
				M.append_to_buffer("}}}")
			else
				local comment = vim.fn.input("Comment (optional): ")
				M.append_to_buffer("{{{ Stopped at " .. args.command .. "\n")
				if comment and comment ~= "" then
					res.content = "[sys] User stopped the task. Comment: " .. comment
					M.append_to_buffer("Comment: " .. comment .. "\n")
				else
					res.content = "[sys] User stopped the task"
				end
				M.append_to_buffer("}}}")
			end
		elseif name == "read_file" then
			if not args.file then
				M.append_to_buffer("{{{ Reading file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end

			M.append_to_buffer("{{{ Reading " .. args.file .. "\n")
			res.content = tools.read_file(args.file, args.range)
			res.file_path = args.file
			res.file_range = args.range
			M.append_to_buffer(res.content .. "\n")
			M.append_to_buffer("}}}")
		elseif name == "connect_file" then
			if not args.file then
				M.append_to_buffer("{{{ Connecting file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end

			M.append_to_buffer("{{{ Connecting " .. args.file .. "\n")
			res.content = tools.read_file(args.file, args.range)
			res.file_path = args.file
			res.file_range = args.range
			M.append_to_buffer(res.content .. "\n")
			M.append_to_buffer("}}}")
		elseif name == "patch" then
			if not args.file then
				M.append_to_buffer("{{{ Patching file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end
			if not args.changes or #args.changes == 0 then
				M.append_to_buffer("{{{ Patching file failed: empty changes field.\n}}}")
				res.content = "[sys] missing empty changes field"
				goto continue
			end

			M.append_to_buffer("{{{ Patching " .. args.file .. "\n")
			for _, change in ipairs(args.changes or {}) do
				if not change.lines or not change.operation then
					M.append_to_buffer("Patching file failed: empty fields.\n}}}")
					res.content = "[sys] patch needs lines and operation fields"
					goto continue
				end

				M.append_to_buffer(string.format(
					"File: %s\nOperation: %s\nLines: %s\nContent:\n%s\n",
					args.file,
					change.operation,
					change.lines,
					change.content
				))
			end

			local out = tools.apply_patch(args.name, args.file, args.changes)
			res.content = out
			M.append_to_buffer("Result:\n" .. (out or "") .. "\n")
			M.append_to_buffer("}}}")
		elseif name == "summarize" then
			M.append_to_buffer("{{{ Summarizing chat\n}}}")
			tai.task(
				{ tools.summary_msg },
				function(summ)
					if summ.error then
						log.error("sumarize error: " .. summ.error)
						return
					end

					res.content = summ.content
					tai.clear_history()
					tai.add_to_history(res)
				end
			)
			return nil
		else
			local err_msg = "[sys] Invalid tool name: " .. name
			M.append_to_buffer("{{{ Invalid tool call\n}}}")
			res.content = err_msg
		end

		::continue::
		refresh_and_close_folds()
		table.insert(results, res)
	end
	return results
end

local function process_response(fields)
	M.open()

	if fields.token_usage then
		vim.schedule(function() update_token_display(fields.token_usage) end)
	end
	if fields.error then
		M.append_to_buffer("[tai] " .. fields.error .. "\n")
		return
	end

	-- Display reasoning details (interleaved thinking) folded
	if fields.reasoning_details and #fields.reasoning_details > 0 then
		M.append_to_buffer("{{{ Reasoning\n" .. fields.reasoning_details[1].text .. "\n}}}")
		vim.schedule(function() refresh_and_close_folds() end)
	end

	if fields.content and fields.content ~= "" then
		M.append_to_buffer(fields.content .. "\n")
	end
	if not fields.tool_calls or #fields.tool_calls == 0 then
		return
	end

	vim.schedule(function()
		local res = run_tools(fields.tool_calls)
		if res then
			tai.task(res, process_response)
		end
	end)
end

local function send_input()
	vim.schedule(function()
		scroll_down()
		local input = table.concat(
			vim.api.nvim_buf_get_lines(M.input_buffer_nr, 0, -1, false),
			"\n"
		)
		vim.api.nvim_buf_set_lines(M.input_buffer_nr, 0, -1, false, {})

		if not input or input == "" then
			return
		end

		vim.schedule(function()
			add_sep()
			M.append_to_buffer(input .. "\n---\n")
		end)

		log.debug("got input: " .. input)
		tai.task({ { role = "user", content = input } }, process_response)
	end)
end

vim.keymap.set("n", "<CR>", send_input, { buffer = M.input_buffer_nr })
vim.keymap.set("i", "<S-CR>", send_input, { buffer = M.input_buffer_nr })

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
			vim.cmd("below split")
			input_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input_win, M.input_buffer_nr)
			vim.api.nvim_win_set_height(input_win, 8)
		else
			chat_win = vim.fn.win_getid(chat_window_nr)
			local input_window_nr = vim.fn.bufwinnr(M.input_buffer_nr)
			if input_window_nr ~= -1 then
				input_win = vim.fn.win_getid(input_window_nr)
			end
		end

		-- Folding is window-local; configure it here so tool output/details can be collapsed.
		if chat_win and vim.api.nvim_win_is_valid(chat_win) then
			vim.wo[chat_win].foldmethod = "marker"
			vim.wo[chat_win].foldenable = true
			vim.wo[chat_win].foldlevel = 0
		end
	end)
end

function M.clear()
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, {})
	tai.clear_history()
end

return M
