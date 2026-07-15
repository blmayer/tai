local M = {}

local log = require("tai.log")
local tools_module = require("tai.tools")

if not require("tai.config").provider then
	return M
end

local current_job = nil
local hard_stop = false
local pending_tools = nil

local function refresh_and_close_folds(M_core)
	if not M_core.chat_win or not vim.api.nvim_win_is_valid(M_core.chat_win) then
		return
	end
	vim.api.nvim_win_call(M_core.chat_win, function()
		local last_line = vim.api.nvim_buf_line_count(M_core.buffer_nr)
		vim.api.nvim_win_set_cursor(M_core.chat_win, { last_line, 0 })
		pcall(vim.cmd, "silent! normal! zc")
	end)
end

local function run_live_shell(command, on_done, M_core)
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
				M_core.append(text)
				table.insert(chunks, text)
			end
		end,
		on_stderr = function(_, data, _)
			if not data then
				return
			end
			local text = table.concat(data, "\n")
			if text ~= "" then
				M_core.append(text)
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
function M.finish_subtask(status, summary, M_core, M_session)
	if #M_session.get_stack() <= 1 then
		return false
	end
	local child = M_session.get_stack()[#M_session.get_stack()]
	local result = tools_module.format_complete(status, summary, child)
	M_core.append(string.format("\n[subtask %s] %s\n}}}\n", status or "ok", summary or ""))
	refresh_and_close_folds(M_core)
	table.remove(M_session.get_stack())
	local parent = M_session.get_stack()[#M_session.get_stack()]
	table.insert(parent.history, {
		role = "tool",
		name = "subtask",
		tool_call_id = child.parent_call_id,
		content = result,
	})
	M_core.update_chat_name()
	M_core.update_input_name()
	M_session.maybe_auto_save(M_core)
	M_core.continue()
	return true
end

local function run_tools(tool_calls, frame, start_index, on_done, M_core, M_session)
	start_index = start_index or 1
	on_done = on_done or function() end
	local stop = false
	local history = frame.history

	if start_index == 1 then
		M_core.append("\n")
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
		local args = vim.json.decode(call["function"].arguments) or {}

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id,
		}

		local function finish_one()
			refresh_and_close_folds(M_core)
			table.insert(history, res)
			if stop then
				on_done(true)
				return
			end
			process_from(i + 1)
		end

		if name == "shell" then
			local unsafe = tools_module.unsafe_command(args.command)
			if not unsafe or require("tai.config").auto_approve then
				local label = unsafe and "Auto-approved" or "Running"
				M_core.append("{{{ " .. label .. ": " .. args.command .. "\n")
				M_core.current_state = "tools"
				M_core.update_input_name()
				run_live_shell(args.command, function(out)
					res.content = tools_module.limit_output(out, "shell")
					M_core.append("\n}}}\n")
					finish_one()
				end, M_core)
				return
			end
			local tcs = {}
			for j = i, #calls do
				table.insert(tcs, calls[j])
			end
			pending_tools = tcs
			M_core.append("Run `" .. args.command .. "`? (y/n/s) ")
			M_core.focus_input()
			on_done(true)
			return
		elseif name == "read" then
			if not args.file then
				M_core.append("{{{ Attaching file failed: no file field.\n}}}")
				res.content = "missing file field"
			elseif vim.fn.filereadable(args.file) ~= 1 then
				M_core.append("{{{ Attaching " .. args.file .. " failed\nFile not readable.}}}\n")
				res.content = "file does not exist or is not readable"
			else
				local range_label = args.range and (" [" .. args.range .. "]") or ""
				M_core.append("{{{ Reading " .. args.file .. range_label .. "\n")
				res.content = tools_module.read_file(args.file, args.range)
				res.file_range = args.range
				M_core.append(res.content .. "\n}}}\n")
			end
		elseif name == "edit" then
			if not args.file then
				M_core.append("{{{ Patching file failed: no file field.\n}}}")
				res.content = "missing file field"
			else
				local out = tools_module.edit(args.file, args.old_text, args.new_text, args.multi)
				res.content = out
				local multi_label = args.multi and " (multi)" or ""
				M_core.append("{{{ " .. out .. multi_label .. "\n" .. (args.old_text or "") .. "\n---\n" .. (args.new_text or "") .. "\n}}}\n")
			end
		elseif name == "write" then
			if not args.file then
				M_core.append("{{{ Write file failed: no file field.\n}}}")
				res.content = "missing file field"
			elseif not args.content then
				M_core.append("{{{ Write file failed: no content field.\n}}}")
				res.content = "missing content field"
			else
				local out = tools_module.write(args.file, args.content)
				res.content = out
				M_core.append("{{{ " .. out .. "\n" .. args.content .. "\n}}}\n")
			end
		elseif name == "subtask" then
			local agent = require("tai.agent")
			if not args.goal or args.goal == "" then
				M_core.append("{{{ Subtask failed: no goal.\n}}}\n")
				res.content = "missing goal"
			elseif type(args.tools) ~= "table" or #args.tools == 0 then
				M_core.append("{{{ Subtask failed: tools list required.\n}}}\n")
				res.content = "missing tools list"
			elseif #M_session.get_stack() >= (agent.MAX_DEPTH or 2) then
				M_core.append("{{{ Subtask failed: max depth.\n}}}\n")
				res.content = "max subtask depth reached"
			else
				local child_tools = agent.sanitize_subtask_tools(args.tools)
				if #child_tools == 0 then
					M_core.append("{{{ Subtask failed: no valid tools.\n}}}\n")
					res.content = "no valid tools"
				else
					local label = args.system_prompt and "custom" or "default"
					M_core.append("{{{ SUBTASK (" .. label .. ")\nGoal: " .. args.goal
						.. "\nTools: " .. table.concat(child_tools, ", ") .. "\n")
					local child = agent.new_frame({
						profile = "subtask",
						system_prompt = args.system_prompt,
						tools = child_tools,
						goal = args.goal,
						notes = args.notes or "",
						todos = args.todos,
						depth = #M_session.get_stack(),
						parent_call_id = call.id,
					})
					table.insert(M_session.get_stack(), child)
					stop = true
					M_core.update_chat_name()
					M_core.update_input_name()
					M_session.maybe_auto_save(M_core)
					M_core.continue()
					on_done(true)
					return
				end
			end
		elseif name == "todos" then
			local out = tools_module.run_todos(args, frame)
			res.content = out
			M_core.append("{{{ Todos (" .. (args.action or "?") .. ")\n" .. out .. "\n}}}\n")
		elseif name == "notes" then
			local out = tools_module.run_notes(args, frame)
			res.content = out
			M_core.append("{{{ Notes (" .. (args.action or "?") .. ")\n" .. out .. "\n}}}\n")
		elseif name == "send_image" then
			if not args.file then
				M_core.append("{{{ Adding image failed: no file field.\n}}}")
				res.content = "Missing file field"
			else
				local image_url, err = tools_module.image_data_url(args.file)
				if not image_url then
					M_core.append("{{{ Adding image " .. args.file .. " failed: " .. err .. "\n}}}")
					res.content = "Error: " .. err
				else
					M_core.append("{{{ Adding image " .. args.file .. "\n}}}")
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
			M_core.append("{{{ Invalid tool name\n}}}\n")
		end

		finish_one()
	end

	process_from(start_index)
end

function M.run_tools(tool_calls, frame, start_index, on_done, M_core, M_session)
	run_tools(tool_calls, frame, start_index, on_done, M_core, M_session)
end

function M.set_hard_stop(value)
	hard_stop = value
end

function M.get_current_job()
	return current_job
end

return M
