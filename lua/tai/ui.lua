local M = {}

-- Global stop flag for hard stop command
local log = require("tai.log")
local tools = require("tai.tools")
local config = require("tai.config")
local agent = require("tai.agent")
local context = require("tai.context")

if not config.provider then
	return M
end

-- Use the new providers factory to get the provider module
local providers_factory = require("tai.providers")
local provider = providers_factory.get_provider(config.provider)

local chat_win
local input_win
local bufname_prefix = "tai-chat"
local input_bufname = "tai-chat-input"

local planner_history = { { role = "system", content = agent.planner_system_prompt } }
local coder_history = { { role = "system", content = agent.coder_system_prompt } }

local planner_config = vim.deepcopy(config)
local coder_config = vim.deepcopy(config)
planner_config.tools = { "read", "shell", "send_image", "coder", "todos", "notes" }
coder_config.tools = { "read", "shell", "send_image", "edit", "write", "todos", "notes", "planner" }

-- Global stop flag for hard stop command
local hard_stop = false
local pending_tools = nil
local current_agent = "planner"  -- Default to planner
local current_job = nil  -- for live shell commands (long-running / progress)
local current_state = "idle"  -- idle | waiting | throttled | thinking | tools

local function get_agent_ctx()
	local hist = (current_agent == "coder") and coder_history or planner_history
	for i = #hist, 1, -1 do
		local msg = hist[i]
		if msg and type(msg.token_usage) == "number" then
			return msg.token_usage
		end
	end
	return nil
end

local function update_input_name()
	-- Derive ctx from the last assistant message in the *current agent's* history
	-- (the authoritative source). No separate per-agent storage.
	-- Responses already insert the assistant message (which carries token_usage)
	-- before update_input_name is called in completion paths.
	local current_ctx = get_agent_ctx()
	local name = input_bufname
	local stats = providers_factory.get_rate_limits()
	local rate_part = string.format("%d req/min, %d tokens/min", stats.requests or 0, stats.tokens or 0)
	if current_ctx then
		name = string.format("%s (ctx: %u | %s)", input_bufname, current_ctx, rate_part)
	else
		name = string.format("%s (%s)", input_bufname, rate_part)
	end
	if M.input_buffer_nr and vim.api.nvim_buf_is_valid(M.input_buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.input_buffer_nr, name)
	end
end

-- Hook into provider throttle notifications to update state indicator
providers_factory.on_throttle = function()
	vim.schedule(function()
		current_state = "throttled"
		update_input_name()
	end)
end

-- Strip stale restore banners so they never stack across sessions.
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
	-- Drop leading blank lines
	while out[1] == "" do
		table.remove(out, 1)
	end
	return out
end

local function get_chat_lines()
	if not M.buffer_nr or not vim.api.nvim_buf_is_valid(M.buffer_nr) then
		return {}
	end
	-- Never persist restore banners
	local lines = vim.api.nvim_buf_get_lines(M.buffer_nr, 0, -1, false)
	return strip_restore_banners(lines)
end

-- Render one agent's history into chat lines matching live UI order:
--   ___ USER ___ / user text / ___ PLANNER|CODER AGENT ___ / assistant (+ tools)
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

	local function agent_sep()
		if #lines > 0 then
			table.insert(lines, "")
		end
		table.insert(lines, "___ " .. agent_label .. " " .. string.rep("_", 40))
	end

	local function user_sep()
		if #lines > 0 then
			table.insert(lines, "")
		end
		table.insert(lines, "___ USER " .. string.rep("_", 40))
	end

	for _, msg in ipairs(hist or {}) do
		if not msg or msg.role == "system" then
			goto continue
		end
		if msg.role == "user" then
			user_sep()
			push(msg.content)
		elseif msg.role == "assistant" then
			-- Agent turn header belongs before the assistant reply (live UI does this
			-- after each user message via add_sep before M.continue).
			agent_sep()
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
					local name = fn.name or "?"
					local args = fn.arguments or ""
					table.insert(lines, "{{{ Tool call: " .. name)
					push(type(args) == "string" and args or vim.inspect(args))
					table.insert(lines, "}}}")
				end
			end
		elseif msg.role == "tool" then
			local name = msg.name or "tool"
			table.insert(lines, "{{{ " .. name)
			push(msg.content)
			table.insert(lines, "}}}")
		end
		::continue::
	end
	return lines
end

-- True if chat_lines look like a real transcript (not empty / only whitespace).
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
	-- Prefer exact buffer snapshot (both agent streams as the user saw them).
	if chat_lines_usable(data.chat_lines) then
		lines = strip_restore_banners(vim.deepcopy(data.chat_lines))
		log.info(string.format(
			"[persist] restoring chat_lines (%d lines); agent=%s planner_msgs=%d coder_msgs=%d",
			#lines,
			tostring(data.current_agent or current_agent),
			#(data.planner_history or planner_history),
			#(data.coder_history or coder_history)
		))
	else
		-- Fallback: rebuild from both histories (planner then coder if used).
		log.info(string.format(
			"[persist] rebuilding chat from histories; agent=%s planner_msgs=%d coder_msgs=%d",
			tostring(data.current_agent or current_agent),
			#planner_history,
			#coder_history
		))
		lines = history_to_chat_lines(planner_history, "PLANNER AGENT")
		if #coder_history > 1 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local coder_lines = history_to_chat_lines(coder_history, "CODER AGENT")
			for _, l in ipairs(coder_lines) do
				table.insert(lines, l)
			end
		end
	end

	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, lines)
	log.info(string.format("[persist] chat buffer restored (%d lines, agent=%s)", #lines, current_agent))
end

local function save_session()
	if not config.context or not config.context.enabled then
		log.debug("[persist] save_session skipped: disabled")
		return
	end
	local ok = context.save({
		planner_history = planner_history,
		coder_history = coder_history,
		current_agent = current_agent,
		last_ctx = get_agent_ctx(),
		todos_store = tools.todos_store,
		todos_next_id = tools.todos_next_id,
		notes_store = tools.notes_store,
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

local function load_session()
	planner_history = { { role = "system", content = agent.planner_system_prompt } }
	coder_history = { { role = "system", content = agent.coder_system_prompt } }
	current_agent = "planner"
	tools.todos_store = {}
	tools.todos_next_id = 1
	tools.notes_store = ""
	pending_tools = nil
	hard_stop = false

	if not config.context or not config.context.enabled then
		log.info("[persist] load_session skipped: context disabled")
		return
	end

	local data = context.load(config.context)
	if not data then
		log.info("[persist] starting fresh session (nothing loaded)")
		return
	end

	if type(data.planner_history) == "table" and #data.planner_history > 0 then
		planner_history = data.planner_history
		-- Ensure system prompt is present as first message
		if not planner_history[1] or planner_history[1].role ~= "system" then
			table.insert(planner_history, 1, { role = "system", content = agent.planner_system_prompt })
		end
	end
	if type(data.coder_history) == "table" and #data.coder_history > 0 then
		coder_history = data.coder_history
		if not coder_history[1] or coder_history[1].role ~= "system" then
			table.insert(coder_history, 1, { role = "system", content = agent.coder_system_prompt })
		end
	end
	if data.current_agent == "coder" or data.current_agent == "planner" then
		current_agent = data.current_agent
	end
	if type(data.todos_store) == "table" then
		tools.todos_store = data.todos_store
	end
	if type(data.todos_next_id) == "number" then
		tools.todos_next_id = data.todos_next_id
	end
	if type(data.notes_store) == "string" then
		tools.notes_store = data.notes_store
	end

	restore_chat_buffer(data)
	log.info("[persist] session restored into UI state")
end

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

	-- Persist session and autoclose TAI UI buffers on Neovim exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("TaiUiCleanup", { clear = true }),
		callback = function()
			if config.context and config.context.enabled and config.context.save_on_shutdown then
				log.info("[persist] VimLeavePre: saving session on shutdown")
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
load_session()
	M.update_chat_name()
	update_input_name()
end

function M.append(content)
	local new_lines = vim.split(content, "\n")

	local function do_append()
		local line_num = vim.api.nvim_buf_line_count(M.buffer_nr)
		local cur_content = vim.api.nvim_buf_get_lines(M.buffer_nr, -2, -1, false)

		-- Non-streaming mode: append new lines normally
		if not cur_content or not cur_content[1] then
			-- Buffer is empty, replace it
			vim.api.nvim_buf_set_lines(M.buffer_nr, 0, 0, false, new_lines)
		else
			-- Append new lines to the end (after the last line)
			cur_content[1] = cur_content[1] .. content
			local new_content = vim.split(cur_content[1], "\n")
			vim.api.nvim_buf_set_lines(M.buffer_nr, line_num - 1, line_num, false, new_content)
		end
	end

	if vim.in_fast_event() then
		vim.schedule(do_append)
	else
		do_append()
	end
end

function M.update_chat_name()
	local name = bufname_prefix
	local state_part = current_state or "idle"
	if config and config.provider and config.model then
		name = string.format("%s (%s/%s - %s) [%s]", bufname_prefix, config.provider, config.model, current_agent, state_part)
	else
		name = string.format("%s %s [%s]", bufname_prefix, current_agent, state_part)
	end
	if M.buffer_nr and vim.api.nvim_buf_is_valid(M.buffer_nr) then
		pcall(vim.api.nvim_buf_set_name, M.buffer_nr, name)
	end
end

function M.update_input_name()
	update_input_name()
end

function M.switch_agent()
	if current_agent == "planner" then
		current_agent = "coder"
	else
		current_agent = "planner"
	end
	M.update_chat_name()
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

		-- Only auto-scroll if the cursor is not in the chat window,
		-- or if it is in the chat window and on the last line already.
		local current_win = vim.api.nvim_get_current_win()
		if current_win == chat_win then
			local cursor_line = vim.api.nvim_win_get_cursor(chat_win)[1]
			local last_line = vim.api.nvim_buf_line_count(M.buffer_nr)
			-- Allow a small margin (cursor within 2 lines of the end)
			if cursor_line < last_line - 2 then
				return
			end
		end

		local original_win = current_win
		vim.api.nvim_set_current_win(chat_win)

		-- Check if input window exists and get its height
		local scroll_cmd = "normal! zz"
		if input_win and vim.api.nvim_win_is_valid(input_win) then
			local input_height = vim.api.nvim_win_get_height(input_win)
			if input_height > 0 then
				-- Use z- command to position last line at bottom, accounting for input window space
				scroll_cmd = "normal! z-"
			end
		end

		vim.api.nvim_win_set_cursor(chat_win, { vim.api.nvim_buf_line_count(M.buffer_nr), 0 })
		vim.cmd(scroll_cmd)
		vim.api.nvim_set_current_win(original_win)
	end)
end

local function add_sep(title)
	local width = vim.api.nvim_win_get_width(chat_win)
	local result = title
	for _ = 1, width - #title do
		result = result .. "_"
	end
	M.append("\n" .. result .. "\n")
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

-- Run a shell command fully asynchronously (does not block the Neovim main thread).
-- Streams stdout/stderr live via M.append. Invokes on_done(full_output) when finished.
-- The caller must write the opening "{{{ Running: ..." line (and the closing in on_done).
local function run_live_shell(command, on_done)
	local chunks = {}
	local shell = vim.o.shell or "sh"
	local flag = vim.o.shellcmdflag or "-c"
	local full_cmd = command .. " 2>&1"
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

	local job = vim.fn.jobstart({ shell, flag, full_cmd }, {
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

	-- Poll hard_stop without blocking the main loop (previous jobwait loop froze UI).
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

-- Run tool calls; shell runs async and resumes the chain via on_done(stop).
-- on_done(stop): stop=true means do not call M.continue (pending confirm, agent switch, hard stop).
local function run_tools(tool_calls, history, start_index, on_done)
	start_index = start_index or 1
	on_done = on_done or function() end
	local stop = false

	if start_index == 1 then
		M.append("\n")
	end

	local function process_from(i)
		if hard_stop then
			log.debug("[UI] run_tools aborted by hard_stop at index " .. tostring(i))
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
		local args = vim.json.decode(call["function"].arguments)

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
			local unsafe = tools.unsafe_command(args.command)
			if not unsafe or config.auto_approve then
				log.debug("Executing allowed command: " .. args.command)
				local label = unsafe and "Auto-approved" or "Running"
				M.append("{{{ " .. label .. ": " .. args.command .. "\n")
				current_state = "tools"
				update_input_name()
				run_live_shell(args.command, function(out)
					local limited = tools.limit_output(out, "shell")
					M.append("\n}}}\n")
					res.content = limited
					finish_one()
				end)
				return -- async; do not block main thread
			end

			-- Pending confirmation: remaining tools from this index
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
				res.content = tools.read_file(args.file, args.range)
				res.file_range = args.range
				M.append(res.content .. "\n}}}\n")
			end
		elseif name == "edit" then
			if not args.file then
				M.append("{{{ Patching file failed: no file field.\n}}}")
				res.content = "missing file field"
			else
				local out = tools.edit(args.file, args.old_text, args.new_text, args.multi)
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
				local out = tools.write(args.file, args.content)
				res.content = out
				M.append("{{{ " .. out .. "\n" .. args.content .. "\n}}}\n")
			end
		elseif name == "coder" then
			if not args.prompt then
				M.append("{{{ Calling coder failed: no prompt field.\n}}}\n")
				res.content = "Missing prompt field"
			else
				M.append("{{{ Calling coder agent\nPrompt:\n" .. args.prompt .. "\n}}}\n")
				add_sep("___ CODER AGENT ")

				stop = true
				res.content = "coder is working on the task."
				coder_history = {
					{ role = "system", content = agent.coder_system_prompt },
					{ role = "user", content = args.prompt }
				}
				current_agent = "coder"
				M.update_chat_name()
				update_input_name()
				maybe_auto_save()

				M.continue()
			end
		elseif name == "planner" then
			if not args.prompt then
				M.append("{{{ Calling planner failed: no prompt field.\n}}}\n")
				res.content = "Missing prompt field"
			else
				M.append("{{{ Calling planner agent\nReport:\n" .. args.prompt .. "\n}}}\n")
				add_sep("___ PLANNER AGENT ")

				res.content = "planner is working on the task."
				table.insert(planner_history, {
					role = "user",
					content = "Coder agent has completed its work and handed back. Report from coder:\n\n" .. args.prompt
				})
				current_agent = "planner"
				M.update_chat_name()
				update_input_name()
				maybe_auto_save()

				M.continue()
				stop = true
			end
		elseif name == "todos" then
			local out = tools.run_todos(args)
			res.content = out
			M.append("{{{ Todos (" .. (args.action or "?") .. ")\n" .. out .. "\n}}}\n")
		elseif name == "notes" then
			local out = tools.run_notes(args)
			res.content = out
			M.append("{{{ Notes (" .. (args.action or "?") .. ")\n" .. out .. "\n}}}\n")
		elseif name == "send_image" then
			if not args.file then
				M.append("{{{ Addind image failed: no file field.\n}}}")
				res.content = "Missing file field"
			else
				local image_url, err = tools.image_data_url(args.file)
				if not image_url then
					M.append("{{{ Adding image " .. args.file .. " failed: " .. err .. "\n}}}")
					res.content = "Error: " .. err
				else
					res.content = "Image " .. args.file .. " added."
					M.append("{{{ Adding image " .. args.file .. "\n}}}")

					local content = {}
					if args.prompt then
						table.insert(content, {
							type = "text",
							text = args.prompt
						})
					end
					table.insert(content, {
						type = "image_url",
						image_url = { url = image_url }
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

		-- Handle pending confirmation
		local history = (current_agent == "coder") and coder_history or planner_history

		if pending_tools and #pending_tools > 0 then
			log.debug("executing pending tool calls " .. vim.inspect(pending_tools))
			local call = pending_tools[1]
			local args = vim.json.decode(call["function"].arguments)
			local res = {
				role = "tool",
				name = call["function"].name,
				tool_call_id = call.id,
			}
			local response = input:lower():gsub("^%s*(.-)%s*$", "%1")

			M.append(input .. "\n")

local function after_pending_tools()
				maybe_auto_save()
				log.debug("[UI] got user input (pending tools done): " .. input)
				if current_agent == "coder" then
					add_sep("___ CODER AGENT ")
				else
					add_sep("___ PLANNER AGENT ")
				end
				M.continue()
				update_input_name()
			end

			if response == "y" or response == "yes" then
				log.debug("Confirmed")
				M.append("Confirmed...\n")
				M.append("{{{ Running: " .. args.command .. "\n")
				run_live_shell(args.command, function(out)
					local limited = tools.limit_output(out, "shell")
					M.append("\n}}}\n")
					res.content = limited
					table.insert(history, res)
					table.remove(pending_tools, 1)
					run_tools(pending_tools, history, 1, function(stop)
						if stop or hard_stop then
							log.debug("[UI] stopped")
							maybe_auto_save()
							return
						end
						after_pending_tools()
					end)
				end)
				return -- async shell
			elseif response == "s" or response == "stop" then
				log.debug("Stopped")
				M.append("Stopped\n")
				M.append("{{{ Stopped at " .. args.command .. " (user: " .. input .. ")\n}}}\n")
				hard_stop = true
				res.content = "User stopped execution."
				table.insert(history, res)
				table.remove(pending_tools, 1)
				maybe_auto_save()
				return
			else
				log.debug("Declined")
				M.append("{{{ Declined " .. args.command .. " (user: " .. input .. ")\n}}}\n")
				res.content = "User declined running this command"
				log.debug("Declined (invalid response)")
				table.insert(history, res)
				table.remove(pending_tools, 1)
				run_tools(pending_tools, history, 1, function(stop)
					if stop or hard_stop then
						log.debug("[UI] stopped")
						maybe_auto_save()
						return
					end
					after_pending_tools()
				end)
				return
			end
		else
			table.insert(history, { role = "user", content = input })

			add_sep("___ USER ")
			M.append(input .. "\n")
		end

		log.debug("[UI] got user input: " .. input)
		if current_agent == "coder" then
			add_sep("___ CODER AGENT ")
		else
			add_sep("___ PLANNER AGENT ")
		end
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
			vim.api.nvim_win_set_height(input_win, 12)

			-- Folding is window-local; configure it here so tool output/details can be collapsed.
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
	planner_history = { { role = "system", content = agent.planner_system_prompt } }
	coder_history = { { role = "system", content = agent.coder_system_prompt } }
	current_agent = "planner"
	tools.todos_store = {}
	tools.todos_next_id = 1
	tools.notes_store = ""
	pending_tools = nil
	pcall(function()
		providers_factory.cancel_pending_waits()
	end)
	if config.context and config.context.enabled then
		log.info("[persist] clear: removing session file")
		context.clear(config.context)
	end
	M.update_chat_name()
	update_input_name()
end

function M.continue()
	local is_coder = current_agent == "coder"
	local hist = is_coder and coder_history or planner_history
	local cfg = is_coder and coder_config or planner_config
	local agent_label = is_coder and "Coder Agent" or "Agent"

	current_state = "waiting"
	update_input_name()

	if config.stream then
		log.info(agent_label .. " executing streaming task")

		local think_start = true
		local content_start = true
		provider.request_stream(
			cfg,
			hist,
			function(chunk, err)
				if err then
					current_state = "idle"
					update_input_name()
					M.append("\n{{{ Chunk error\n" .. err .. "\n}}}\n")
					return
				end

				log.debug("[UI] got chunk data: " .. vim.inspect(chunk))
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
				log.debug("[UI] updated chat")
			end,
			function(data, err)
				log.debug("[UI] got message completed: " .. vim.inspect(data))
				if err then
					current_state = "idle"
					update_input_name()
					M.append("{{{ Received error\n" .. err .. "\n}}}\n")
					table.insert(hist, { role = "assistant", content = err })
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
					current_state = "idle"
					update_input_name()
					maybe_auto_save()
					if is_coder then
						log.debug("[UI] coder finished (no more tool calls)")
					end
					return
				end

				current_state = "tools"
				update_input_name()
				log.debug("[UI] running tools")
				run_tools(data.tool_calls, hist, 1, function(stop)
					maybe_auto_save()
					if stop or hard_stop then
						log.debug("[UI] stopped")
						return
					end
					M.continue()
				end)
			end
		)
	else
		log.info(agent_label .. " executing task")
		provider.request(
			cfg,
			hist,
			function(fields, err)
				if err then
					current_state = "idle"
					update_input_name()
					M.append("{{{ Error\n" .. err .. "\n}}}")
					table.insert(hist, { role = "assistant", content = err })
					maybe_auto_save()
					return
				end
				local response = { role = "assistant" }
				for k, v in pairs(fields) do
					response[k] = v
				end
				table.insert(hist, response)

				log.debug("[UI] processing response: " .. vim.inspect(fields))
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

				-- For non-streaming responses, append the content to the buffer
				if fields.content and fields.content ~= vim.NIL and fields.content ~= "" then
					M.append(fields.content .. "\n")
				end

				if not fields.tool_calls or #fields.tool_calls == 0 then
					current_state = "idle"
					update_input_name()
					maybe_auto_save()
					if is_coder then
						log.debug("[UI] coder finished (no more tool calls)")
					end
					return
				end

				vim.schedule(function()
					current_state = "tools"
					update_input_name()
					log.debug("[UI] running tools")
					run_tools(fields.tool_calls, hist, 1, function(stop)
						maybe_auto_save()
						if stop or hard_stop then
							log.debug("[UI] stopped")
							return
						end
						M.continue()
					end)
				end)
			end
		)
	end
end

return M
