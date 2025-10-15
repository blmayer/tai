local M = {}

local log = require('tai.log')
local config = require("tai.config")
local agents = require("tai.agents")
local library = require("tai.library")
local planner = require("tai.agents.planner")
local coder = require("tai.agents.coder")
local patcher = require("tai.agents.patcher")
local writer = require("tai.agents.writer")
local command = require("tai.command")
local ui = require("tai.ui")
local tools = require("tai.tools")

local completion_prompt =
"You are an autocomplete assistant. You will receive the current line, you job is to return the remaining part, don't add any formatting. Line:\n"

function M.init()
	if not config.root or config.skip_cache then
		return
	end
	log.info("Starting Tai, provider " .. config.provider)

	agents.init()
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

local function handle_coder_req(req, cb)
	log.debug("handling coder request: " .. req)
	coder.task(
		req,
		function(data, err)
			if data.patcher then
				log.debug("coder reply to patcher: " .. data.patcher)
				patcher.create_patch(
					data.patcher,
					function(p, err) 
						log.debug("patcher reply: " .. p)
						cb(data.writer, p)
					end
				)
			end
		end
	)
end

local function handle_planner_reply(reply)
	log.info("handling reply")

	if reply.tools then
		ui.show_tool_calls(reply.tools)
		planner.run_tools(
			reply.tools,
			function(data, err)
				if err then
					ui.show_response({ error = err })
					return
				end
				return handle_planner_reply(data)
			end
		)
	end

	if not reply.coder then
		log.debug("calling writer after planner: " .. reply.writer)
		writer.write(
			reply.writer,
			function(data, err) ui.show_response(data) end
		)
		return
	end

	-- planner called coder
	handle_coder_req(
		reply.coder,
		function(res, err)
			writer.write(
				reply.writer .. res.text,
				function(data, err)
					ui.show_response(
						{
							unpack(data),
							patch = res.patch
						}
					)
				end
			)
		end

	)


	-- if reply.commands then
	-- 	vim.api.nvim_buf_create_user_command(
	-- 		ui.buffer_nr,
	-- 		'RunTaiCommand',
	-- 		function()
	-- 			local out = run_commands(reply.commands)
	-- 			reply = planner.plan(out)
	-- 			ui.show_response(reply)
	-- 		end,
	-- 		{}
	-- 	)
	-- end
end

function M.process_request(prompt)
	log.debug("Processing request " .. prompt)

	planner.plan(
		prompt,
		function(reply, err)
			if err then
				log.error("received error from planner: " .. err)
				return
			end

			vim.schedule(function() handle_planner_reply(reply) end)
		end
	)
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
