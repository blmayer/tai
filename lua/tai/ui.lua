local M = {}
local log = require("tai.log")
local tools = require("tai.tools")
local config = require("tai.config")
local agent = require("tai.agent")

if not config.provider then
	return M
end
local provider = require("tai." .. config.provider)

local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

local chat_win
local input_win

-- Global stop flag for hard stop command
local hard_stop = false

function M.init()
	M.input_buffer_nr = vim.api.nvim_create_buf(true, false) -- scratch buffer, not listed
	vim.api.nvim_buf_set_name(M.input_buffer_nr, input_bufname)
	vim.bo[M.input_buffer_nr].buftype = "nofile"
	vim.bo[M.input_buffer_nr].bufhidden = "hide"
	vim.bo[M.input_buffer_nr].swapfile = false
	vim.bo[M.input_buffer_nr].filetype = "text"
	vim.bo[M.input_buffer_nr].modifiable = true

	M.buffer_nr = vim.api.nvim_create_buf(false, true)
	vim.bo[M.buffer_nr].buftype = "nofile"
	vim.bo[M.buffer_nr].bufhidden = "hide" -- keep content when hidden
	vim.bo[M.buffer_nr].swapfile = false
	vim.bo[M.buffer_nr].modifiable = true
	vim.bo[M.buffer_nr].filetype = "text"

	-- When typing fold end marker in the chat buffer, refresh/close fold immediately.
	if not config.stream then
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
	end

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
	M.clear()
	M.update_chat_name()
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

function M.update_chat_name()
	local name = bufname_prefix
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s)", bufname_prefix, config.provider, config.model)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

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

local function append_streaming(content)
	local new_lines = vim.split(content, "\n")

	local function do_append()
		local line_num = vim.api.nvim_buf_line_count(M.buffer_nr)
		local cur_content = vim.api.nvim_buf_get_lines(M.buffer_nr, -2, -1, false)

		if line_num == 1 and cur_content[1] == "" then
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 1, false, new_lines)
		else
			content = cur_content[1] .. content
			vim.api.nvim_buf_set_lines(M.buffer_nr, line_num - 1, line_num, false, vim.split(content, "\n"))
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
		log.debug("[UI] running tool: " .. vim.inspect(call))
		local name = call["function"].name
		local args = vim.json.decode(call["function"].arguments)

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}

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
				M.append_to_buffer((out or "") .. "\n}}}\n")
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
			M.append_to_buffer("\n}}}\n")
		elseif name == "track_file" then
			if not args.file then
				M.append_to_buffer("{{{ Attaching file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end
			if vim.fn.filereadable(args.file) ~= 1 then
				M.append_to_buffer("{{{ Attaching file failed: file does not exist or is not readable: " ..
					args.file .. "\n}}}\n")
				res.content = "[sys] file does not exist or is not readable"
				goto continue
			end

			M.append_to_buffer("{{{ Attaching " .. args.file)
			res.content = tools.read_file(args.file, args.range)
			res.file_path = args.file
			res.file_range = args.range
			M.append_to_buffer(res.content .. "\n}}}\n")
		elseif name == "patch" then
			if not args.file then
				M.append_to_buffer("{{{ Patching file failed: no file field.\n}}}")
				res.content = "[sys] missing file field"
				goto continue
			end
			if not args.operation then
				M.append_to_buffer(
					"{{{ Patching file failed: no operation field.\n}}}")
				res.content =
				"[sys] invalid operation field (must be one of 'add', 'update' or 'delete') check the tool definition to know the correct fields."
				goto continue
			end
			if not args.range then
				M.append_to_buffer(
					"{{{ Patching file failed: no range field.\n}}}")
				res.content =
				"[sys] invalid lines range (must be a no-empty string) check the tool definition to know the correct fields."
				goto continue
			end

			M.append_to_buffer("{{{ Patching " .. args.file)
			M.append_to_buffer(string.format(
				"File: %s\nOperation: %s\nRange: %s\nContent:\n%s\n",
				args.file,
				args.operation,
				args.range,
				args.content
			))

			local out = tools.apply_patch(args.name, args.file, args.operation, args.range, args.content)
			res.content = out
			M.append_to_buffer("Result:\n" .. (out or "") .. "\n}}}\n")
		elseif name == "summarize" then
			M.append_to_buffer("{{{ Summarizing chat\n}}}")
			M.task(
				{ tools.summary_msg },
				function(summ)
					if summ.error then
						log.error("sumarize error: " .. summ.error)
						return
					end

					res.content = summ.content
					M.clear_history()
					M.add_to_history({ res })
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
			res.content = "[sys] Invalid tool name: " .. (name or "")
			M.append_to_buffer("{{{ Invalid tool name\n}}}\n")
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

		add_sep()
		M.append_to_buffer(input .. "\n---\n")

		log.debug("[UI] got user input: " .. input)
		if config.stream then
			M.task_stream({ { role = "user", content = input } })
		else
			M.task({ { role = "user", content = input } })
		end
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
	provider.clear_history()
	provider.add_to_history({ role = "system", content = agent.system_prompt })
end

function M.task(msgs)
	log.info("Agent executing task")
	provider.request(
		config,
		msgs,
		nil,
		function(fields, err)
			if err then
				M.append_to_buffer("{{{ Error\n" .. err .. "\n}}}")
			end
			local response = { role = "assistant" }
			for k, v in pairs(fields) do
				response[k] = v
			end
			provider.add_to_history(response)

			log.debug("[UI] processing response: " .. vim.inspect(fields))
			M.open()

			if fields.token_usage then
				update_token_display(fields.token_usage)
			end
			if fields.error then
				M.append_to_buffer("{{{ Provider returned error\n" .. fields.error .. "\n}}}")
			end

			if fields.reasoning then
				M.append_to_buffer("{{{ Thinking\n" .. fields.reasoning .. "\n}}}\n")
				refresh_and_close_folds()
			end

			-- For non-streaming responses, append the content to the buffer
			if fields.content and fields.content ~= vim.NIL and fields.content ~= "" then
				if not config.stream then
					M.append_to_buffer(fields.content .. "\n")
				end
			end

			if not fields.tool_calls or #fields.tool_calls == 0 then
				return
			end

			vim.schedule(function()
				log.debug("[UI] running tools")
				local res, stop = run_tools(fields.tool_calls)
				if stop or hard_stop then
					for _, msg in ipairs(res) do
						provider.add_to_history(msg)
					end
					log.debug("[UI] stopped")
					return
				end
				M.task(res)
			end)
		end
	)
end

-- Streaming task execution
function M.task_stream(msgs)
	log.info("Agent executing streaming task")

	local think_start = true
	local content_start = true
	provider.request_stream(
		config,
		msgs,
		nil,
		function(chunk, err)
			if err then
				append_streaming("\n{{{ Chunk error\n" .. err .. "\n}}}\n")
				return
			end

			log.debug("[UI] got chunk data: " .. vim.inspect(chunk))
			if chunk.reasoning and #chunk.reasoning > 0 then
				if think_start then
					append_streaming("{{{ Thinking \n" .. chunk.reasoning)
					think_start = false
				else
					append_streaming(chunk.reasoning)
				end
			end

			if chunk.content and chunk.content ~= "" then
				if content_start and not think_start then
					append_streaming("\n}}}\n")
					refresh_and_close_folds()
					content_start = false
				end

				append_streaming(chunk.content)
			end
			log.debug("[UI] updated chat")
		end,
		function(data, err)
			log.debug("[UI] got message completed: " .. vim.inspect(data))
			if err then
				append_streaming("{{{ Received error\n" .. err .. "\n}}}\n")
				return
			end
			local response = { role = "assistant" }
			for k, v in pairs(data) do
				response[k] = v
			end
			provider.add_to_history(response)

			if not think_start and content_start then
				append_streaming("\n}}}\n")
			end
			if data.token_usage then
				update_token_display(data.token_usage)
			end
			if data.error then
				M.append_to_buffer("{{{ Provider returned error\n" .. data.error .. "\n}}}")
			end
			if not data.tool_calls or #data.tool_calls == 0 then
				return
			end

			log.debug("[UI] running tools")
			local res, stop = run_tools(data.tool_calls)
			if stop or hard_stop then
				for _, msg in ipairs(res) do
					provider.add_to_history(msg)
				end
				log.debug("[UI] stopped")
				return
			end
			M.task_stream(res)
		end
	)
end

return M
