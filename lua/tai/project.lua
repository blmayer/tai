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
	local output = ""

	for _, cmd in ipairs(cmds) do
		log.debug("Running command `" .. cmd["function"]["name"] .. "`")
		local args = vim.json.decode(cmd["function"].arguments)
		local file = io.open(args.file_path, "r")
		if file then
			local content = file:read("*all")
			file:close()
			output = output .. "\n\n[tai] Content of " .. args.file_path .. ":\n" .. content .. "\n"
		else
			output = output .. "\n\n[tai] File " .. args.file_path .. " not found"
		end
	end

	vim.schedule(function()
		vim.notify("[tai] Sending commands output", vim.log.levels.TRACE)
	end)

	return output
end

function M.process_request(prompt, callback)
	log.debug("Processing request " .. prompt)

	if config.provider == "mistral" then
		planner.receive_prompt(prompt, callback)
	else
		local reply = chat.send(config.model, prompt)
		ui.show_response(prompt, reply)

		::continue::

		if reply.tools then
			ui.show_tool_calls(reply.tools)
			local out = run_tool_calls(reply.tools)
			reply = chat.send(config.model, "Result of tool calls:\n" .. out)
			goto continue
		end
		if reply.patch then
			vim.api.nvim_buf_create_user_command(
				bufnr,
				'ApplyTaiPatch',
				function() apply_patch(reply.patch) end,
				{}
			)
		end
		if reply.commands then
			vim.api.nvim_buf_create_user_command(
				bufnr,
				'RunTaiCommand',
				function()
					local out = run_commands(fields.commands)
					reply = chat.send(config.model, out)
					ui.show_response(reply)
				end,
				{}
			)
		end
	end
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

	vim.schedule(function()
		vim.notify("[tai] Sending commands output", vim.log.levels.TRACE)
	end)

	return output
end

function apply_patch(patch)
	local real = io.popen("ed -s > /dev/null 2>&1", "w")
	real:write(patch)
	real:close()
	vim.api.nvim_command("checktime")
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
