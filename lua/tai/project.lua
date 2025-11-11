local M = {}

local log = require('tai.log')
local config = require("tai.config")
local agents = require("tai.agents")
local tai = require("tai.agents.tai")
local tools = require("tai.agents.tools")
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

-- local function handle_coder_req(req, cb)
-- 	log.debug("handling coder request: " .. req)
-- 	coder.task(
-- 		req,
-- 		function(reply, err)
-- 			if reply.tool_calls then
-- 				ui.show_tool_calls(reply.tool_calls)
-- 				coder.run_tools(
-- 					reply.tool_calls,
-- 					function(data, err)
-- 						if err then
-- 							ui.show_response({ error = err })
-- 							return
-- 						end
-- 						return handle_coder_req(data.content.coder, cb)
-- 					end
-- 				)
-- 				return
-- 			end
-- 			if reply.content.patcher then
-- 				log.debug("coder reply to patcher: " .. reply.content.patcher)
-- 				patcher.create_patch(
-- 					reply.content.patcher,
-- 					function(out, err)
-- 						log.debug("patcher reply: " .. out.content)
-- 						cb(
-- 							{ content = { writer = reply.content.writer, patcher = out.content } },
-- 							nil)
-- 					end
-- 				)
-- 				return
-- 			end
-- 			cb({ content = { writer = reply.content.writer } }, nil)
-- 		end
-- 	)
-- end
--
-- local function handle_planner_reply(reply)
-- 	log.info("handling reply")
--
-- 	if reply.tool_calls then
-- 		ui.show_tool_calls(reply.tool_calls)
-- 		planner.run_tools(
-- 			reply.tool_calls,
-- 			function(data, err)
-- 				if err then
-- 					ui.show_response({ error = err })
-- 					return
-- 				end
-- 				return handle_planner_reply(data)
-- 			end
-- 		)
-- 		return
-- 	end
--
-- 	if not reply.content.coder then
-- 		if not reply.content.writer then
-- 			log.error("planner did not sent writer field")
-- 			ui.show_response({ error = "Planner did not sent writer field" })
-- 			return
-- 		end
--
-- 		log.debug("calling writer after planner: " .. reply.content.writer)
-- 		writer.write(
-- 			reply.content.writer,
-- 			function(data, err)
-- 				if err then
-- 					log.error("writer gave error: " .. err)
-- 					ui.show_response({ error = err })
-- 					return
-- 				end
-- 				ui.show_response(data.content)
-- 			end
-- 		)
-- 		return
-- 	end
--
-- 	-- planner called coder
-- 	handle_coder_req(
-- 		reply.content.coder,
-- 		function(res, err)
-- 			local text = res.content.writer or ""
-- 			if reply.content.writer then
-- 				text = reply.content.writer .. "\n\n" .. text
-- 			end
-- 			log.debug("calling writer after coder/patcher: " .. text)
-- 			writer.write(
-- 				text,
-- 				function(data, err)
-- 					ui.show_response(
-- 						{
-- 							plan = data.content.plan,
-- 							text = data.content.text,
-- 							patch = res.content.patcher
-- 						}
-- 					)
-- 				end
-- 			)
-- 		end
-- 	)
-- end
--
-- function M.process_request(prompt)
-- 	log.debug("Processing request " .. prompt)
--
-- 	planner.plan(
-- 		prompt,
-- 		function(reply, err)
-- 			if err then
-- 				log.error("received error from planner: " .. err)
-- 				ui.show_response({ error = err })
-- 				return
-- 			end
--
-- 			vim.schedule(function() handle_planner_reply(reply) end)
-- 		end
-- 	)
-- end

-- function(data, err)
-- 	if err then
-- 		ui.show_response({ error = err })
-- 		return
-- 	end
-- 	return handle_chat_reply(data)
-- end

local function handle_chat_reply(reply)
	log.info("handling chat reply")

	ui.show_response(reply)
	if reply.tool_calls then
		for _, call in ipairs(reply.tool_calls) do
			local name = call["function"].name
			local args = call["function"].arguments

			local out
			if name == "run" then
				log.debug("Asking for confirmation")
				local input = vim.fn.confirm("Run " .. args.command .. "?", "&y\n&N", 2)
				if input == 1 then
					log.debug("Confirmed")
					out = tools.run(name, args)
				else
					log.debug("Declined")
					out = "[sys] User declined"
				end
			else
				out = tools.run(name, args)
			end

			tai.add_to_history(
				{
					role = "tool",
					content = out,
					tool_call_id = call.id
				}
			)
		end

		return M.chat("I added the tool calls outputs, continue with the task.")
	end
end

function M.chat(prompt)
	log.debug("Processing chat request " .. prompt)
	tai.task(
		prompt,
		function(reply, err)
			if err then
				log.error("received error from agent: " .. err)
				ui.show_response({ error = err })
				return
			end

			vim.schedule(function() handle_chat_reply(reply) end)
		end
	)
end

function M.clear_history()
	tai.clear_history()
	ui.clear()
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
