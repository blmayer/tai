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

M.input_buffer_nr = vim.api.nvim_create_buf(true, false) -- scratch buffer, not listed
vim.api.nvim_buf_set_name(M.input_buffer_nr, input_bufname)
vim.bo[M.input_buffer_nr].buftype = 'nofile'
vim.bo[M.input_buffer_nr].bufhidden = 'hide'
vim.bo[M.input_buffer_nr].swapfile = false
vim.bo[M.input_buffer_nr].filetype = 'text'
vim.bo[M.input_buffer_nr].modifiable = true

M.buffer_nr = vim.api.nvim_create_buf(false, true)
M.update_chat_name()
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

local function scroll_down()
	vim.schedule(function()
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
	for i = 1, width do
		result = result .. "_"
	end
	M.append_to_buffer(result .. "\n")
end

local function run_tools(tool_calls)
	local results = {}
	for _, call in ipairs(tool_calls or {}) do
		local name = call["function"].name
		local args = call["function"].arguments

		local res = {
			role = "tool",
			name = name,
			tool_call_id = call.id
		}
		if name == "shell" then
			log.debug("Asking for confirmation")
			local input = vim.fn.confirm("Run " .. args.command .. "?", "&Y\n&n\n&s (stop)", 1)
			if input == 1 then
				log.debug("Confirmed")
				M.append_to_buffer("[tai] Running " .. args.command .. "\n")
				res.content = tools.run(name, args)
			elseif input == 2 then
				log.debug("Declined")
				M.append_to_buffer("[tai] Declined " .. args.command .. "\n")
				res.content = "[sys] User declined running this command"
			else
				M.append_to_buffer("[tai] Stopped at " .. args.command .. "\n")
				res.content = "[sys] User stopped the conversation"
				table.insert(results, res)
				return results
			end
		elseif name == "read_file" then
			M.append_to_buffer("[tai] Reading " .. args.file_path .. "\n")
			res.content = tools.run(name, args)
			res.file_path = args.file_path
		elseif name == "patch" then
			M.append_to_buffer("[tai] Patching " .. args.file .. "\n")
			if args.name then
				M.append_to_buffer("[tai] " .. args.name .. "\n")
			end
			for _, change in ipairs(args.changes) do
				M.append_to_buffer(string.format(
					"Operation: %s, Lines: %s\nContent:\n%s\n",
					change.operation,
					change.lines,
					change.content
				))
			end
			res.content = tools.run(name, args)
		elseif name == "summarize" then
			M.append_to_buffer("[tai] Summarizing\n")
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
		end
		log.debug("Output of " .. name .. ": " .. (res.content or ""))
		table.insert(results, res)
	end
	return results
end

local function process_response(fields)
	log.debug("Showing response")
	M.open()

	if fields.error then
		M.append_to_buffer("[tai] " .. fields.error .. "\n")
		return
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
			'\n'
		)
		vim.api.nvim_buf_set_lines(M.input_buffer_nr, 0, -1, false, {})

		if not input or input == "" then return end
		vim.schedule(function()
			add_sep()
			M.append_to_buffer(input .. "\n")
		end)

		log.debug("got input: " .. input)
		tai.task({ { role = "user", content = input } }, process_response)
	end)
end

vim.keymap.set('n', '<CR>', send_input, { buffer = M.input_buffer_nr })
vim.keymap.set('i', '<S-CR>', send_input, { buffer = M.input_buffer_nr })

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
		end
	end)
end

function M.clear()
	vim.api.nvim_buf_set_lines(M.buffer_nr, 0, -1, false, {})
	tai.clear_history()
end

return M
