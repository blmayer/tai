local M = {}

local log = require('tai.log')
local config = require("tai.config")
local agents = require("tai.agents")
local library = require("tai.library")
local planner = require("tai.agents.planner")
local chat = require("tai.chat")
local command = require("tai.command")
local ui = require("tai.ui")

local completion_prompt =
"You are an autocomplete assistant. You will receive the current line, you job is to return the remaining part, don't add any formatting. Line:\n"


function M.init()
	if not config.root or config.skip_cache then
		return
	end
	log.info("Starting Tai, provider " .. config.provider)

	if config.provider == "mistral" then
		local files = vim.fn.glob('**/*', true, true)
		library.setup(function(library_id, err)
			if err then
				log.error("Failed to setup library: " .. err)
				return
			end
			log.info("Library initialized with ID: " .. library_id)

			agents.init()
			log.info("Agents init complete")

			-- initial sync
			library.sync(files)
		end)
	end
end

local function run_tool_calls(cmds)
	log.debug("Running tools")
	local output = ""

	for _, cmd in ipairs(cmds) do
		log.debug("Running command `" .. cmd["function"]["name"] .. "`")
		local args = vim.json.decode(cmd["function"].arguments)
		local file = io.open(args.file_path, "r")
		if file then
			local content = file:read("*all")
			file:close()

			local numbered_lines = {}
			for i, line in ipairs(vim.split(content, '\n', { plain = true })) do
				table.insert(numbered_lines, string.format("%d: %s", i, line))
			end
			local numbered_content = table.concat(numbered_lines, "\n")
			output = output .. "\n\n[tai] Content of " .. args.file_path .. ":\n" .. numbered_content .. "\n"
		else
			output = output .. "\n\n[tai] File " .. args.file_path .. " not found"
		end
	end

	return output
end

local function run_commands(cmds)
	local output = ""

	for _, cmd in ipairs(cmds) do
		log.debug("Running command `" .. cmd .. "`")
		if not command.validate(cmd, config.allowed_commands) then
			output = "[tai] Command " .. cmd .. " is not allowed"
		end

		local out = command.run(cmd)
		if out then
			output = output .. "\n\n[tai] Output of ```" .. cmd .. "```:\n" .. out
		else
			output = output .. "\n\n[tai] ```" .. cmd .. "``` returned null"
		end
	end

	return output
end

local function apply_patch(patch)
	local real = io.popen("ed -s 2>&1", "w")
	if not real then
		vim.notify("[tai] failed to apply patch: popen is null", vim.log.levels.ERROR)
		return
	end

	real:write(patch)
	local output = real:read("*all")
	real:close()

	if output then
		log.debug("Patch application output: " .. output)
	end
	vim.api.nvim_command("checktime")
end

local function handle_reply(reply)
	::continue::

	if reply.tools then
		ui.show_tool_calls(reply.tools)
		local out = run_tool_calls(reply.tools)
		reply = chat.send("Result of tool calls:\n" .. out)
		goto continue
	end
	if reply.patch then
		vim.api.nvim_buf_create_user_command(
			ui.buffer_nr,
			'ApplyTaiPatch',
			function() apply_patch(reply.patch) end,
			{}
		)
	end
	if reply.commands then
		vim.api.nvim_buf_create_user_command(
			ui.buffer_nr,
			'RunTaiCommand',
			function()
				local out = run_commands(reply.commands)
				reply = chat.send(out)
				ui.show_response(reply)
			end,
			{}
		)
	end
	ui.show_response(reply)
end

function M.process_request(prompt)
	log.debug("Processing request " .. prompt)

	if config.provider == "mistral" then
		planner.receive_prompt(
			prompt,
			function(reply, err)
				vim.schedule(function()
					handle_reply(reply)
				end)
			end
		)
	else
		local reply = chat.send(prompt)
		handle_reply(reply)
	end
end

--function M.complete(start)
--	-- Get current buffer content
--	local bufnr = vim.api.nvim_get_current_buf()
--	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
--	local content = table.concat(lines, "\n")
--
--	local msgs = {
--		{ role = "system",    content = content },
--		{ role = "user",      content = completion_prompt .. start },
--		{ role = "assistant", content = start }
--	}
--
--	local reply = chat.send_raw(config.complete_model, msgs)
--	if not reply then return nil end
--
--	return reply
--end


return M
