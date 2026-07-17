local M = {}

local log = require("tai.log")
local config = require("tai.config")
local agent = require("tai.agent")
local context = require("tai.context")
local tools_io = require("tai.tools.io")
local tools_shell = require("tai.tools.shell")
local tools_edit = require("tai.tools.edit")
local tools_subtask = require("tai.tools.subtask")
local tools_skill = require("tai.tools.skill")

if not config.provider then
	return M
end

local providers_factory = require("tai.providers")
local provider = providers_factory.get_provider(config.provider)

local chat_win
local input_win
local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

-- Agent stack: main frame at [1], optional subtask on top
local stack = { agent.new_frame({ profile = "main" }) }

local hard_stop = false
local pending_tools = nil
local current_job = nil
local current_state = "idle" -- idle | waiting | throttled | thinking | tools

local function top()
	return stack[#stack]
end

local function prepare_messages(frame)
	local msgs = vim.deepcopy(frame.history)
	if msgs[1] and msgs[1].role == "system" then
		local live = tools_subtask.render_memory(frame)
		if live ~= "" then
			-- Single system message (providers that allow only one); never stored in history.
			msgs[1].content = frame.system_prompt .. "\n\n" .. live
		else
			msgs[1].content = frame.system_prompt
		end
	end
	return msgs
end

local function frame_config(frame)
	local cfg = vim.deepcopy(config)
	cfg.tools = frame.tools
	return cfg
end

local function get_agent_ctx()
	local hist = top().history
	for i = #hist, 1, -1 do
		local msg = hist[i]
		if msg and type(msg.token_usage) == "number" then
			return msg.token_usage
		end
	end
	return nil
end

local function update_input_name()
	local current_ctx = get_agent_ctx()
	local stats = providers_factory.get_rate_limits()
	local rate_part = string.format("%d req/min, %d tokens/min", stats.requests or 0, stats.tokens or 0)
	local name
	if current_ctx then
		name = string.format("%s (ctx: %u | %s)", input_bufname, current_ctx, rate_part)
	else
		name = string.format("%s (%s)", input_bufname, rate_part)
	end
	if M.input_buffer_nr and vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.input_buffer_nr, name)
	end
end

providers_factory.on_throttle = function()
	vim.schedule(function()
		current_state = "throttled"
		update_input_name()
	end)
end

local function strip_restore_banners(lines)
	local out = {}
	local i = 1
	while i <= #lines do
		local line = lines[i]
		if type(line) == "string" and line:match("^%[tai%] Restored session") then
			i = i + 1
			if lines[i] == "" then
				i = i + 1
			end
		else
			table.insert(out, line)
			i = i + 1
		end
	end
	while out[1] == "" do
		table.remove(out, 1)
	end
	return out
end

local function get_chat_lines()
	if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
		return {}
	end
	return strip_restore_banners(vim.api.nvim_buf_get_lines(M.buffer_nr, 0, -1, false))
end

local function history_to_chat_lines(hist, agent_label)
	local lines = {}
	local function push(text)
		if text == nil or text == vim.NIL then
			return
		end
		if type(text) ~= "string" then
			text = vim.inspect(text)
		end
		for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
			table.insert(lines, line)
		end
	end
	local function sep(title)
		if #lines > 0 then
			table.insert(lines, "")
		end
		table.insert(lines, "___ " .. title .. " " .. string.rep("_", 40))
	end

	for _, msg in ipairs(hist or {}) do
		if not msg or msg.role == "system" then
			goto continue
		end
		if msg.role == "user" then
			sep("USER")
			push(msg.content)
		elseif msg.role == "assistant" then
			sep(agent_label)
			if msg.reasoning and msg.reasoning ~= "" and msg.reasoning ~= vim.NIL then
				table.insert(lines, "{{{ Thinking")
				push(msg.reasoning)
				table.insert(lines, "}}}")
			end
			if msg.content and msg.content ~= "" and msg.content ~= vim.NIL then
				push(msg.content)
			end
			if msg.tool_calls and #msg.tool_calls > 0 then
				for _, call in ipairs(msg.tool_calls) do
					local fn = call["function"] or {}
					table.insert(lines, "{{{ Tool call: " .. (fn.name or "?"))
					local args = fn.arguments or ""
					push(type(args) == "string" and args or vim.inspect(args))
					table.insert(lines, "}}}")
				end
			end
		elseif msg.role == "tool" then
			table.insert(lines, "{{{ " .. (msg.name or "tool"))
			push(msg.content)
			table.insert(lines, "}}}")
		end
		::continue::
	end
	return lines
end

local function chat_lines_usable(chat_lines)
	if type(chat_lines) ~= "table" or #chat_lines == 0 then
		return false
	end
	for _, line in ipairs(chat_lines) do
		if type(line) == "string" and line:match("%S") and not line:match("^%[tai%] Restored session") then
			return true
		end
	end
	return false
end

local function restore_chat_buffer(data)
	if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
		return
	end
	local lines
	if chat_lines_usable(data.chat_lines) then
		lines = strip_restore_banners(vim.deepcopy(data.chat_lines))
		log.info(string.format("[persist] restoring chat_lines (%d lines)", #lines))
	else
		local main = stack[1]
		log.info("[persist] rebuilding chat from main history")
		lines = history_to_chat_lines(main and main.history, "MAIN")
	end
	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, lines)
end

local function save_session()
	if not config.context or not config.context.enabled then
		return
	end
	local ok = context.save({
		stack = stack,
		last_ctx = get_agent_ctx(),
		chat_lines = get_chat_lines(),
	}, config.context)
	if not ok then
		log.warning("[persist] save_session failed")
	end
end

local function maybe_auto_save()
	if config.context and config.context.enabled and config.context.auto_save then
		save_session()
	end
end

local function ensure_system(frame)
	if not frame.history[1] or frame.history[1].role ~= "system" then
		table.insert(frame.history, 1, { role = "system", content = frame.system_prompt })
	end
end

function M.init()
	M.input_buffer_nr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(M.input_buffer_nr, input_bufname)
	vim.bo[M.input_buffer_nr].buftype = "nofile"
	vim.bo[M.input_buffer_nr].bufhidden = "hide"
	vim.bo[M.input_buffer_nr].swapfile = false
	vim.bo[M.input_buffer_nr].filetype = "text"
	vim.bo[M.input_buffer_nr].modifiable = true

	M.buffer_nr = vim.api.nvim_create_buf(false, true)
	vim.bo[M.buffer_nr].buftype = "nofile"
	vim.bo[M.buffer_nr].bufhidden = "hide"
	vim.bo[M.buffer_nr].swapfile = false
	vim.bo[M.buffer_nr].modifiable = true
	vim.bo[M.buffer_nr].filetype = "text"

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

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("TaiUiCleanup", { clear = true }),
		callback = function()
			if config.context and config.context.enabled and config.context.save_on_shutdown then
				save_session()
			end
			if vim.api.nvim_buf_is_valid(M.buffer_nr) then
				vim.api.nvim_buf_delete(M.buffer_nr, { force = true })
			end
			if vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
				vim.api.nvim_buf_delete(M.input_buffer_nr, { force = true })
			end
		end,
	})
	vim.keymap.set("n", "<CR>", M.send_input, { buffer = M.input_buffer_nr })
	vim.keymap.set("i", "<S-CR>", M.send_input, { buffer = M.input_buffer_nr })

	M.update_chat_name()
	update_input_name()
end

function M.append(content)
	local new_lines = vim.split(content, "\n")
	local function do_append()
		local line_num = vim.api.nvim_buf_line_count(M.buffer_nr)
		local cur_content = vim.api.nvim_buf_get_lines(M.buffer_nr, -2, -1, false)
		if not cur_content or not cur_content[1] then
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 0, false, new_lines)
		else
			cur_content[1] = cur_content[1] .. content
			local merged = vim.split(cur_content[1], "\n")
			vim.api.nvim_buf_set_lines(M.buffer_nr, line_num - 1, line_num, false, merged)
		end
	end
	if vim.in_fast_event() then
		vim.schedule(do_append)
	else
		do_append()
	end
end

function M.update_chat_name()
	local fr = top()
	local role = fr and fr.label or "MAIN"
	local state_part = current_state or "idle"
	local name
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s - %s) [%s]", bufname_prefix, config.provider, config.model, role, state_part)
	else
		name = string.format("%s %s [%s]", bufname_prefix, role, state_part)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

function M.update_input_name()
	update_input_name()
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
		local current_win = vim.api.nvim_get_current_win()
		if current_win == chat_win then
			local cursor_line = vim.api.nvim_win_get_cursor(chat_win)[1]
			local last_line = vim.api.nvim_buf_line_count(M.buffer_nr)
			if cursor_line < last_line - 2 then
				return
			end
		end
		local original_win = current_win
		vim.api.nvim_set_current_win(chat_win)
		local scroll_cmd = "normal! zz"
		if input_win and vim.api.nvim_win_is_valid(input_win) then
			scroll_cmd = "normal! z-"
		end
		vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(M.buffer_nr), 0 })
		vim.cmd(scroll_cmd)
		vim.api.nvim_set_current_win(original_win)
	end)
end

local function add_sep(title)
	local width = 80
	if chat_win and vim.api.nvim_win_is_valid(chat_win) then
		width = vim.api.nvim_win_get_width(chat_win)
	end
	local result = title
	for _ = 1, math.max(0, width - #title) do
		result = result .. "_"
	end
	M.append("\n" .. result .. "\n")
end

local function refresh_and_close_folds()
	if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
		return
	end
	vim.api.nvim_win_call(chat_win, function()
		local last_line = vim.api.nvim_buf_line_count(M.buffer_nr)
		vim.api.nvim_win_set_cursor(chat_win, { last_line, 0 })
		pcall(vim.cmd, "silent! normal! zc")
	end)
end

local function run_live_shell(command, on_done)
	local chunks = {}
	local shell = vim.o.shell or "sh"
	local flag = vim.o.shellcmdflag or "-c"
	local finished = false
	local stop_timer = nil

	local function finish(out)
		if finished then
			return
		end
		finished = true
		current_job = nil
		if stop_timer then
			pcall(function()
				stop_timer:stop()
				stop_timer:close()
			end)
			stop_timer = nil
		end
		vim.schedule(function()
			on_done(out)
		end)
	end

	local job = vim.fn.jobstart({ shell, flag, command .. " 2>&1" }, {
		on_stdout = function(_, data, _)
			if not data then
				return
			end
			local text = table.concat(data, "\n")
			if text ~= "" then
				M.append(text)
				table.insert(chunks, text)
			end
		end,
		on_stderr = function(_, data, _)
			if not data then
				return
			end
			local text = table.concat(data, "\n")
			if text ~= "" then
				M.append(text)
				table.insert(chunks, text)
			end
		end,
		on_exit = function(_, code, _)
			local full = table.concat(chunks, "")
			if (code or 0) ~= 0 then
				full = full .. "\n[exit " .. tostring(code or 0) .. "]"
			end
			finish(full)
		end,
		stdout_buffered = false,
		stderr_buffered = false,
	})

	current_job = job
	if job <= 0 then
		finish("Failed to start: " .. command)
		return
	end

	stop_timer = vim.uv.new_timer()
	stop_timer:start(100, 100, vim.schedule_wrap(function()
		if finished then
			return
		end
		if hard_stop then
			log.info("[UI] hard_stop: stopping shell job " .. tostring(job))
			pcall(vim.fn.jobstop, job)
		end
	end))
end

-- Finish current subtask: pop stack, deliver tool result to parent, resume.
local function finish_subtask(status, summary)
	if #stack <= 1 then
		return false
	end
	local child = top()
	local result = tools_subtask.format_complete(status, summary, child)
	M.append(string.format("\n[subtask %s] %s\n}}}\n", status or "ok", summary or ""))
	refresh_and_close_folds()
	table.remove(stack)
	local parent = top()
	table.insert(parent.history, {
		role = "tool",
		name = "subtask",
		tool_call_id = child.parent_call_id,
		content = result,
	})
	M.update_chat_name()
	update_input_name()
	maybe_auto_save()
	M.continue()
	return true
end

local function run_tools(tool_calls, frame, start_index, on_done)
	start_index = start_index or 1
	on_done = on_done or function() end
	local stop = false
	local history = frame.history

	if start_index == 1 then
		M.append("\n")
	end

	local function process_from(i)
		if hard_stop then
			on_done(true)
			return
		end

		local calls = tool_calls or {}
		if i > #calls then
			on_done(stop)
			return
		end

		local call = calls[i]
		log.debug("[UI] running tool: " .. vim.inspect(call))
		local name = call["function"].name
		local ok_args, args = pcall(vim.json.decode, call["function"].arguments or "{}")
		if not ok_args or type(args) ~= "table" then
			args = {}
		end

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}

		local function finish_one()
			refresh_and_close_folds()
			table.insert(history, res)
			if stop then
				on_done(true)
				return
			end
			process_from(i + 1)
		end

		if name == "shell" then
			local unsafe = tools_shell.unsafe_command(args.command)
			if not unsafe or config.auto_approve then
				local label = unsafe and "Auto-approved" or "Running"
				M.append("{{{ " .. label .. ": " .. args.command .. "\n")
				current_state = "tools"
				update_input_name()
				run_live_shell(args.command, function(out)
					res.content = tools_io.limit_output(out, "shell")
					M.append("\n}}}\n")
					finish_one()
				end)
				return
			end
			local tcs = {}
			for j = i, #calls do
				table.insert(tcs, calls[j])
			end
			pending_tools = tcs
			M.append("Run `" .. args.command .. "`? (y/n/s) ")
			M.focus_input()
			on_done(true)
			return
		elseif name == "read" then
			if not args.file then
				M.append("{{{ Attaching file failed: no file field.\n}}}")
				res.content = "missing file field"
			elseif vim.fn.filereadable(args.file) ~= 1 then
				M.append("{{{ Attaching " .. args.file .. " failed\nFile not readable.}}}\n")
				res.content = "file does not exist or is not readable"
			else
				local range_label = args.range and (" [" .. args.range .. "]") or ""
				M.append("{{{ Reading " .. args.file .. range_label .. "\n")
				res.content = tools_io.read_file(args.file, args.range)
				res.file_range = args.range
				M.append(res.content .. "\n}}}\n")
			end
		elseif name == "edit" then
			if not args.file then
				M.append("{{{ Patching file failed: no file field.\n}}}")
				res.content = "missing file field"
			else
				local out = tools_edit.edit(args.file, args.old_text, args.new_text, args.multi, config)
				res.content = out
				local multi_label = args.multi and " (multi)" or ""
				M.append("{{{ " .. out .. multi_label .. "\n" .. (args.old_text or "") .. "\n---\n" .. (args.new_text or "") .. "\n}}}\n")
			end
		elseif name == "write" then
			if not args.file then
				M.append("{{{ Write file failed: no file field.\n}}}")
				res.content = "missing file field"
			elseif not args.content then
				M.append("{{{ Write file failed: no content field.\n}}}")
				res.content = "missing content field"
			else
				local out = tools_subtask.write(args.file, args.content)
				res.content = out
				M.append("{{{ " .. out .. "\n" .. args.content .. "\n}}}\n")
			end
		elseif name == "subtask" then
			if not args.goal or args.goal == "" then
				M.append("{{{ Subtask failed: no goal.\n}}}\n")
				res.content = "missing goal"
			elseif type(args.tools) ~= "table" or #args.tools == 0 then
				M.append("{{{ Subtask failed: tools list required.\n}}}\n")
				res.content = "missing tools list"
			elseif #stack >= (agent.MAX_DEPTH or 2) then
				M.append("{{{ Subtask failed: max depth.\n}}}\n")
				res.content = "max subtask depth reached"
			else
				local child_tools = agent.sanitize_subtask_tools(args.tools)
				if #child_tools == 0 then
					M.append("{{{ Subtask failed: no valid tools after sanitize.\n}}}\n")
					res.content = "no valid tools"
				else
					local label = args.system_prompt and "custom" or "default"
					M.append("{{{ SUBTASK (" .. label .. ")\nGoal: " .. args.goal
						.. "\nTools: " .. table.concat(child_tools, ", ") .. "\n")
					local child = agent.new_frame({
						profile = "subtask",
						system_prompt = args.system_prompt,
						tools = child_tools,
						goal = args.goal,
						notes = args.notes or "",
						todos = args.todos,
						depth = #stack,
						parent_call_id = call.id,
					})
					table.insert(stack, child)
					stop = true
					M.update_chat_name()
					update_input_name()
					maybe_auto_save()
					M.continue()
					on_done(true)
					return
				end
			end
		elseif name == "todos" then
			local out = tools_subtask.run_todos(args, frame)
			res.content = out
			local todos_content = tools_subtask.format_todos(frame.todos)
			M.append("{{{ Todos (" .. (args.action or "?") .. ")\nAction result: " .. out .. "\n\nCurrent todos:\n" .. todos_content .. "\n}}}\n")
		elseif name == "notes" then
			local out = tools_subtask.run_notes(args, frame)
			res.content = out
			local notes_content = frame.notes ~= "" and frame.notes or "(empty)"
			M.append("{{{ Notes (" .. (args.action or "?") .. ")\nAction result: " .. out .. "\n\nNotes content:\n" .. notes_content .. "\n}}}\n")
		elseif name == "skill" then
			local out = tools_skill.run(args)
			res.content = out
			M.append("{{{ Skill (" .. (args.action or "?") .. ")\n" .. out .. "\n}}}\n")
		elseif name == "send_image" then
			if not args.file then
				M.append("{{{ Adding image failed: no file field.\n}}}")
				res.content = "Missing file field"
			else
				local image_url, err = tools_subtask.image_data_url(args.file)
				if not image_url then
					M.append("{{{ Adding image " .. args.file .. " failed: " .. err .. "\n}}}")
					res.content = "Error: " .. err
				else
					M.append("{{{ Adding image " .. args.file .. "\n}}}")
					local content = {}
					if args.prompt then
						table.insert(content, { type = "text", text = args.prompt })
					end
					table.insert(content, {
						type = "image_url",
						image_url = { url = image_url },
					})
					res.content = content
				end
			end
		else
			res.content = "Invalid tool name: " .. (name or "")
			M.append("{{{ Invalid tool name\n}}}\n")
		end

		finish_one()
	end

	process_from(start_index)
end

function M.send_input()
	if hard_stop then
		hard_stop = false
	end

	vim.schedule(function()
		scroll_down()
		local input = table.concat(vim.api.nvim_buf_get_lines(M.input_buffer_nr, 0, -1, false), "\n")
		vim.api.nvim_buf_set_lines(M.input_buffer_nr, 0, -1, false, {})
		if not input or input == "" then
			return
		end

		local frame = top()
		local history = frame.history

		if pending_tools and #pending_tools > 0 then
			local call = pending_tools[1]
			local args = vim.json.decode(call["function"].arguments)
			local res = {
				role = "tool",
				name = call["function"].name,
				tool_call_id = call.id,
			}
			local response = input:lower():gsub("^%s*(.-)%s*$", "%1")
			M.append(input .. "\n")

			local function after_pending()
				maybe_auto_save()
				add_sep("___ " .. (frame.label or "AGENT") .. " ")
				M.continue()
				update_input_name()
			end

			if response == "y" or response == "yes" then
				M.append("Confirmed...\n")
				M.append("{{{ Running: " .. args.command .. "\n")
				run_live_shell(args.command, function(out)
					res.content = tools_shell.limit_output(out, "shell")
					M.append("\n}}}\n")
					table.insert(history, res)
					table.remove(pending_tools, 1)
					run_tools(pending_tools, frame, 1, function(stop)
						if stop or hard_stop then
							maybe_auto_save()
							return
						end
						after_pending()
					end)
				end)
				return
			elseif response == "s" or response == "stop" then
				M.append("Stopped\n")
				M.append("{{{ Stopped at " .. args.command .. " (user: " .. input .. ")\n}}}\n")
				hard_stop = true
				res.content = "User stopped execution."
				table.insert(history, res)
				table.remove(pending_tools, 1)
				maybe_auto_save()
				return
			else
				M.append("{{{ Declined " .. args.command .. " (user: " .. input .. ")\n}}}\n")
				res.content = "User declined running this command"
				table.insert(history, res)
				table.remove(pending_tools, 1)
				run_tools(pending_tools, frame, 1, function(stop)
					if stop or hard_stop then
						maybe_auto_save()
						return
					end
					after_pending()
				end)
				return
			end
		else
			table.insert(history, { role = "user", content = input })
			add_sep("___ USER ")
			M.append(input .. "\n")
		end

		add_sep("___ " .. (frame.label or "AGENT") .. " ")
		maybe_auto_save()
		M.continue()
		update_input_name()
	end)
end

function M.stop()
	hard_stop = true
	if current_job then
		pcall(vim.fn.jobstop, current_job)
		current_job = nil
	end
	pcall(function()
		providers_factory.cancel_pending_waits()
	end)
	M.append("\n[tai] Stopped by user\n")
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

			vim.cmd("below split")
			input_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input_win, M.input_buffer_nr)
			vim.api.nvim_win_set_height(input_win, 12)

			if chat_win and vim.api.nvim_win_is_valid(chat_win) then
				vim.wo[chat_win].foldmethod = "marker"
				vim.wo[chat_win].foldenable = true
				vim.wo[chat_win].foldlevel = 0
			end
		else
			chat_win = vim.fn.win_getid(chat_window_nr)
			vim.api.nvim_win_set_width(chat_win, 80)
			local input_window_nr = vim.fn.bufwinnr(M.input_buffer_nr)
			if input_window_nr ~= -1 then
				input_win = vim.fn.win_getid(input_window_nr)
			end
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
	stack = { agent.new_frame({ profile = "main" }) }
	pending_tools = nil
	pcall(function()
		providers_factory.cancel_pending_waits()
	end)
	if config.context and config.context.enabled then
		context.clear(config.context)
	end
	M.update_chat_name()
	update_input_name()
end

function M.continue()
	local frame = top()
	local hist = frame.history
	local cfg = frame_config(frame)
	local msgs = prepare_messages(frame)
	local agent_label = frame.label or "AGENT"

	current_state = "waiting"
	update_input_name()

	local function on_idle_no_tools(content)
		-- Subtask finished: final assistant text (+ notes/todos) returns to parent
		if #stack > 1 then
			finish_subtask("ok", content or "(no output)")
			return
		end
		current_state = "idle"
		update_input_name()
		maybe_auto_save()
	end

	local function handle_tools(tool_calls)
		current_state = "tools"
		update_input_name()
		local ok, err = pcall(run_tools, tool_calls, frame, 1, function(stop)
			maybe_auto_save()
			if stop or hard_stop then
				return
			end
			M.continue()
		end)
		if not ok then
			log.error("[UI] run_tools failed: " .. tostring(err))
			M.append("{{{ Tool runner error\n" .. tostring(err) .. "\n}}}\n")
			current_state = "idle"
			update_input_name()
		end
	end

	if config.stream then
		log.info(agent_label .. " streaming")
		local think_start = true
		local content_start = true
		provider.request_stream(cfg, msgs, function(chunk, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("\n{{{ Chunk error\n" .. err .. "\n}}}\n")
				return
			end
			if type(chunk) ~= "table" then
				return
			end
			if chunk.reasoning and #chunk.reasoning > 0 then
				if think_start then
					current_state = "thinking"
					update_input_name()
					M.append("{{{ Thinking \n" .. chunk.reasoning)
					think_start = false
				else
					M.append(chunk.reasoning)
				end
			end
			if chunk.content and chunk.content ~= "" then
				if content_start and not think_start then
					M.append("\n}}}\n")
					refresh_and_close_folds()
					content_start = false
				end
				M.append(chunk.content)
			end
		end, function(data, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("{{{ Received error\n" .. err .. "\n}}}\n")
				table.insert(hist, { role = "assistant", content = err })
				return
			end
			if type(data) ~= "table" then
				current_state = "idle"
				update_input_name()
				local msg = "empty provider response"
				M.append("{{{ Received error\n" .. msg .. "\n}}}\n")
				table.insert(hist, { role = "assistant", content = msg })
				maybe_auto_save()
				return
			end
			local response = { role = "assistant" }
			for k, v in pairs(data) do
				response[k] = v
			end
			table.insert(hist, response)

			if not think_start and content_start then
				M.append("\n}}}\n")
			end
			if data.token_usage then
				update_input_name()
			end
			if data.error then
				M.append("{{{ Provider returned error\n" .. data.error .. "\n}}}")
			end
			if not data.tool_calls or #data.tool_calls == 0 then
				on_idle_no_tools(data.content)
				return
			end
			handle_tools(data.tool_calls)
		end)
	else
		log.info(agent_label .. " request")
		provider.request(cfg, msgs, function(fields, err)
			if err then
				current_state = "idle"
				update_input_name()
				M.append("{{{ Error\n" .. err .. "\n}}}")
				table.insert(hist, { role = "assistant", content = err })
				maybe_auto_save()
				return
			end
			if type(fields) ~= "table" then
				current_state = "idle"
				update_input_name()
				local msg = "empty provider response"
				M.append("{{{ Error\n" .. msg .. "\n}}}")
				table.insert(hist, { role = "assistant", content = msg })
				maybe_auto_save()
				return
			end
			local response = { role = "assistant" }
			for k, v in pairs(fields) do
				response[k] = v
			end
			table.insert(hist, response)
			M.open()

			if fields.token_usage then
				update_input_name()
			end
			if fields.error then
				M.append("{{{ Provider returned error\n" .. fields.error .. "\n}}}")
			end
			if fields.reasoning then
				M.append("{{{ Thinking\n" .. fields.reasoning .. "\n}}}\n")
				refresh_and_close_folds()
			end
			if fields.content and fields.content ~= vim.NIL and fields.content ~= "" then
				M.append(fields.content .. "\n")
			end
			if not fields.tool_calls or #fields.tool_calls == 0 then
				on_idle_no_tools(fields.content)
				return
			end
			vim.schedule(function()
				handle_tools(fields.tool_calls)
			end)
		end)
	end
end

return M
