local M = {}

local log = require("tai.log")
local config = require("tai.config")
local agent = require("tai.agent")

if not config.provider then
	return M
end

local providers_factory = require("tai.providers")
local provider = providers_factory.get_provider(config.provider)

-- Import submodules
local ui_core = require("tai.ui.core")
local ui_session = require("tai.ui.session")
local ui_tools = require("tai.ui.tools")

-- Export core functions from submodules
for k, v in pairs(ui_core) do
	M[k] = v
end

-- Agent stack: main frame at [1], optional subtask on top
ui_session.set_stack({ agent.new_frame({ profile = "main" }) })

-- Re-export session functions
for k, v in pairs(ui_session) do
	M[k] = v
end

-- Re-export tools functions
for k, v in pairs(ui_tools) do
	M[k] = v
end

-- Set up references between modules
ui_core.chat_win = nil
ui_core.input_win = nil
ui_core.buffer_nr = nil
ui_core.input_buffer_nr = nil
ui_core.current_state = "idle" -- idle | waiting | throttled | thinking | tools
ui_core.pending_tools = nil

-- Export core module functions with proper references
M.init = ui_core.init
M.append = ui_core.append
M.update_chat_name = ui_core.update_chat_name
M.update_input_name = ui_core.update_input_name
M.focus_input = ui_core.focus_input
M.send_input = ui_core.send_input
M.stop = ui_core.stop
M.open = ui_core.open
M.toggle_chat_window = ui_core.toggle_chat_window
M.clear = ui_core.clear
M.continue = ui_core.continue

-- Export session module functions
M.load_session = function() ui_session.load_session(ui_core) end
M.save_session = function() ui_session.save_session(ui_core) end
M.maybe_auto_save = function() ui_session.maybe_auto_save(ui_core) end
M.clear_session = function() ui_session.clear_session(ui_core) end

-- Export tools module functions
M.finish_subtask = function(status, summary) ui_tools.finish_subtask(status, summary, ui_core, ui_session) end
M.run_tools = function(tool_calls, frame, start_index, on_done) ui_tools.run_tools(tool_calls, frame, start_index, on_done, ui_core, ui_session) end

return M
