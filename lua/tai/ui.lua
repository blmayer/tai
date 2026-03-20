local M = {}
local log = require("tai.log")
local tai = require("tai.agent")
local tools = require("tai.tools")
local config = require("tai.config")

local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

local chat_win
local input_win

-- Global stop flag for hard stop command
local hard_stop = false

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

function M.update_chat_name()
	local name = bufname_prefix
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s)", bufname_prefix, config.provider, config.model)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

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

function M.focus_input()
	vim.schedule(function()
		vim.api.nvim_set_current_win(input_win)
		vim.cmd("startinsert")
	end)
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
		-- Move to last line and close fold there (the fold we just added)
		local last_line = vim.api.nvim_buf_line_count(M.buffer_nr)
		vim.api.nvim_win_set_cursor(chat_win, { last_line, 0 })
		pcall(vim.cmd, "silent! normal! zc")
	end)
end

local function run_tools(tool_calls)
	local results = {}
	local stop = false
	local inputs = {}

	for _, call in ipairs(tool_calls or {}) do
		local name = call["function"].name
		local args = call["function"].arguments

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}
		--
		-- Check for hard stop before each tool
		if hard_stop then
			goto continue
		end

		if name == "shell" then

			if not tools.unsafe_command(args.command) then
				-- Allowed command: execute directly without confirmation
				log.debug("Executing allowed command: " .. args.command)
				M.append_to_buffer("{{{ Running: " .. args.command .. "\n")
				local out = tools.exec_command(args.command)
				M.append_to_buffer((out or "") .. "\n}}}")
				res.content = out
				goto continue
			end

			-- Unknown command: ask for confirmation
			log.debug("Asking for confirmation for: " .. args.command)
			local input = vim.fn.confirm(
				"Run `" .. args.command .. "`?",
				"&Y\n&n\n&s (stop)",
				1
			)
			if input == 1 then
				log.debug("Confirmed")
				M.append_to_buffer("{{{ Running: " .. args.command .. "\n")
				local out = tools.exec_command(args.command)
				M.append_to_buffer((out or ""))
				res.content = out
			elseif input == 2 then
				log.debug("Declined")
				local comment = vim.fn.input("Comment (optional): ")
				M.append_to_buffer("{{{ Declined " .. args.command .. "\n")
				if comment and comment ~= "" then
					res.content = "[sys] User declined running this command. Comment: " ..
					    comment
					M.append_to_buffer("Comment: " .. comment)
				else
					res.content = "[sys] User declined running this command"
				end
			else
				local comment = vim.fn.input("Comment (optional): ")
				M.append_to_buffer("{{{ Stopped at " .. args.command)
				if comment and comment ~= "" then
					res.content = "[sys] User stopped the task. Comment: " .. comment
					M.append_to_buffer("Comment: " .. comment)
				else
					res.content = "[sys] User stopped the task"
				end
				stop = true
			end
			M.append_to_buffer("\n}}}")
		elseif name == "track_file" then
			if not args.file then
				M.append_to_buffer("{{{ Attaching file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end
            if vim.fn.filereadable(args.file) ~= 1 then
                M.append_to_buffer("{{{ Attaching file failed: file does not exist or is not readable: " .. args.file .. "\n}}}")
                res.content = "[sys] file does not exist or is not readable"
                goto continue
            end


			M.append_to_buffer("{{{ Attaching " .. args.file)
			res.content = tools.read_file(args.file, args.range)
			res.file_path = args.file
			res.file_range = args.range
			M.append_to_buffer(res.content .. "\n}}}")
		elseif name == "patch" then
			if not args.file then
				M.append_to_buffer("{{{ Patching file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end
			if not args.changes or type(args.changes) ~= "table" or #args.changes == 0 then
				M.append_to_buffer(
				"{{{ Patching file failed: invalid changes field (must be a non-empty table).\n}}}")
				res.content = "[sys] invalid changes field (must be a non-empty object) check the tool definition to know the correct fields."
				goto continue
			end

			M.append_to_buffer("{{{ Patching " .. args.file)
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
			M.append_to_buffer("Result:\n" .. (out or "") .. "\n}}}")
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
					tai.add_to_history({ res })
				end
			)
			return nil
		elseif name == "send_image" then
			if not args.file then
				M.append_to_buffer("{{{ Addind image failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end

			local image_url, err = tools.image_data_url(args.file)
			if not image_url then
				M.append_to_buffer("{{{ Adding image " .. args.file .. " failed: " .. err .. "\n}}}")
				res.content = "[sys] Error: " .. err
				goto continue
			end
			res.content = "[sys] Image " .. args.file .. " added."
			M.append_to_buffer("{{{ Adding image " .. args.file .. "\n}}}")

			if args.prompt then
				table.insert(inputs, {
					role = "user",
					content = {
						type = "text",
						text = args.prompt
					}
				})
			end
			table.insert(inputs, {
				role = "user",
				content = {
					type = "image_url",
					image_url = { url = image_url }
				}
			})
		else
			res.content = "[sys] Invalid tool name: " .. name
			M.append_to_buffer("{{{ Invalid tool call\n}}}")
		end

		::continue::
		refresh_and_close_folds()
		table.insert(results, res)
	end


	-- Second pass is needed for image inputs
	if #inputs > 0 then
		for _, i in ipairs(inputs) do
			table.insert(results, i)
		end
	end
	return results, stop
end

local function process_response(fields)
	M.open()

	if fields.token_usage then
		vim.schedule(function() update_token_display(fields.token_usage) end)
	end
	if fields.error then
		M.append_to_buffer("{{{ Provider returned error\n" .. fields.error .. "\n}}}")
		return
	end

	-- Display reasoning details (interleaved thinking) folded
	if fields.reasoning_details and #fields.reasoning_details > 0 then
		M.append_to_buffer("{{{ Reasoning\n" .. fields.reasoning_details[1].text .. "}}}")
		vim.schedule(function() refresh_and_close_folds() end)
	end

	if fields.content then
		if fields.content ~= vim.NIL and fields.content ~= "" then
			M.append_to_buffer(fields.content .. "\n")
		end
	end
	if not fields.tool_calls or #fields.tool_calls == 0 then
		return
	end

	vim.schedule(function()
		local res, stop = run_tools(fields.tool_calls)
		if stop or hard_stop then
			tai.add_to_history(res)
			return
		end
		tai.task(res, process_response)
	end)
end

local function send_input()
	-- reset hard stop when user sends a message
	if hard_stop then
		hard_stop = false
	end

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

function M.stop()
	hard_stop = true
	M.append_to_buffer("[tai] Stopped by user\n")
end

vim.keymap.set("n", "<CR>", send_input, { buffer = M.input_buffer_nr })
vim.keymap.set("i", "<S-CR>", send_input, { buffer = M.input_buffer_nr })

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

			-- Folding is window-local; configure it here so tool output/details can be collapsed.
			if chat_win and vim.api.nvim_win_is_valid(chat_win) then
				vim.wo[chat_win].foldmethod = "marker"
				vim.wo[chat_win].foldenable = true
				vim.wo[chat_win].foldlevel = 0
			end
		else
			chat_win = vim.fn.win_getid(chat_window_nr)
			local input_window_nr = vim.fn.bufwinnr(M.input_buffer_nr)
			if input_window_nr ~= -1 then
				input_win = vim.fn.win_getid(input_window_nr)
			end
			-- Ensure foldmethod and foldenable are set (but don't reset foldlevel)
			if chat_win and vim.api.nvim_win_is_valid(chat_win) then
				vim.wo[chat_win].foldmethod = "marker"
				vim.wo[chat_win].foldenable = true
			end
		end
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

function M.clear()
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, {})
	tai.clear_history()
end

return M
