local M = {}

local log = require("tai.log")
local config = require("tai.config")
local agent = require("tai.agent")
local context = require("tai.context")
local tools_io = require("tai.tools.io")
local tools_subtask = require("tai.tools.subtask")

if not config.provider then
	return M
end

-- Agent stack: main frame at [1], optional subtask on top
local stack = { agent.new_frame({ profile = "main" }) }

local function top()
	return stack[#stack]
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

local function ensure_system(frame)
	if not frame.history[1] or frame.history[1].role ~= "system" then
		table.insert(frame.history, 1, { role = "system", content = frame.system_prompt })
	end
end

local function restore_chat_buffer(data, M_core)
	if not M_core.buffer_nr or not vim.api.nvim_buf_is_valid(M_core.buffer_nr) then
		return
	end
	local lines
	if tools_io.chat_lines_usable(data.chat_lines) then
		lines = tools_io.strip_restore_banners(vim.deepcopy(data.chat_lines))
		log.info(string.format("[persist] restoring chat_lines (%d lines)", #lines))
	else
		local main = stack[1]
		log.info("[persist] rebuilding chat from main history")
		lines = tools_subtask.history_to_chat_lines(main and main.history, "MAIN")
	end
	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(M_core.buffer_nr, 0, -1, false, lines)
end

local function save_session(M_core)
	if not config.context or not config.context.enabled then
		return
	end
	local ok = context.save({
		stack = stack,
		last_ctx = get_agent_ctx(),
		chat_lines = tools.get_chat_lines(M_core),
	}, config.context)
	if not ok then
		log.warning("[persist] save_session failed")
	end
end

local function maybe_auto_save(M_core)
	if config.context and config.context.enabled and config.context.auto_save then
		save_session(M_core)
	end
end

function M.load_session(M_core)
	stack = { agent.new_frame({ profile = "main" }) }

	if not config.context or not config.context.enabled then
		return
	end

	local data = context.load(config.context)
	if not data then
		return
	end

	if type(data.stack) == "table" and #data.stack > 0 then
		stack = data.stack
		for _, fr in ipairs(stack) do
			fr.notes = fr.notes or ""
			fr.todos = fr.todos or {}
			fr.todos_next_id = fr.todos_next_id or 1
			fr.tools = fr.tools or (agent.profiles[fr.role] and agent.profiles[fr.role].tools)
			fr.system_prompt = fr.system_prompt
				or (agent.profiles[fr.role] and agent.profiles[fr.role].prompt)
				or agent.profiles.main.prompt
			fr.label = fr.label or (fr.role and fr.role:upper()) or "AGENT"
			ensure_system(fr)
		end
	elseif type(data.planner_history) == "table" and #data.planner_history > 0 then
		-- Migrate legacy dual-agent sessions
		local main = agent.new_frame({ profile = "main" })
		main.history = data.planner_history
		main.notes = data.notes_store or ""
		main.todos = data.todos_store or {}
		main.todos_next_id = data.todos_next_id or 1
		ensure_system(main)
		stack = { main }
		log.info("[persist] migrated legacy planner/coder session")
	end

	restore_chat_buffer(data, M_core)
	log.info("[persist] session restored")
end

function M.save_session(M_core)
	save_session(M_core)
end

function M.maybe_auto_save(M_core)
	maybe_auto_save(M_core)
end

function M.get_stack()
	return stack
end

function M.set_stack(new_stack)
	stack = new_stack
end

function M.clear_session(M_core)
	if config.context and config.context.enabled then
		context.clear(config.context)
	end
end

return M
