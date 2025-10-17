local M = {}

local log = require('tai.log')
local config = require("tai.config")
local agents = require("tai.agents")
local planner = require("tai.agents.planner")
local coder = require("tai.agents.coder")
local patcher = require("tai.agents.patcher")
local writer = require("tai.agents.writer")
local command = require("tai.command")
local ui = require("tai.ui")

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
		function(reply, err)
			if reply.tool_calls then
				ui.show_tool_calls(reply.tool_calls)
				coder.run_tools(
					reply.tool_calls,
					function(data, err)
						if err then
							ui.show_response({ error = err })
							return
						end
						return handle_coder_req(data.content.coder, cb)
					end
				)
				return
			end
			if reply.content.patcher then
				log.debug("coder reply to patcher: " .. reply.content.patcher)
				patcher.create_patch(
					reply.content.patcher,
					function(out, err) 
						log.debug("patcher reply: " .. out.content)
						cb({ content = { writer = reply.content.writer, patcher = out.content } }, nil)
					end
				)
				return
			end
			cb({ content = { writer = reply.content.writer } }, nil)
		end
	)
end

local function handle_planner_reply(reply)
	log.info("handling reply")

	if reply.tool_calls then
		ui.show_tool_calls(reply.tool_calls)
		planner.run_tools(
			reply.tool_calls,
			function(data, err)
				if err then
					ui.show_response({ error = err })
					return
				end
				return handle_planner_reply(data)
			end
		)
		return
	end

	if not reply.content.coder then
		if not reply.content.writer then
			log.error("planner did not sent writer field")
			ui.show_response({ error = "[tai] Planner did not sent writer field" })
			return
		end

		log.debug("calling writer after planner: " .. reply.content.writer)
		writer.write(
			reply.content.writer,
			function(data, err)
				if err then
					log.error("writer gave error: " .. err)
					ui.show_response({ error = err })
					return
				end
				ui.show_response(data.content)
			end
		)
		return
	end

	-- planner called coder
	handle_coder_req(
		reply.content.coder,
		function(res, err)
			if reply.content.writer then
				res.content.writer = reply.content.writer .. "\n\n" .. res.content.writer
			end
			writer.write(
				res.content.writer,
				function(data, err)
					ui.show_response(
						{
							unpack(data),
							patch = res.content.patcher
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
				ui.show_response({ error = err })
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
