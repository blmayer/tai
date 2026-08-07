-- MCP (Model Context Protocol) client — Anthropic standard JSON-RPC 2.0.
-- Supports local stdio servers and remote HTTP servers.
-- Does NOT implement: Tool List Change Notifications, Roots, or Sampling.

local M = {}
local log = require("tai.log")

-- Neovim 0.10+ has vim.uv; 0.9 exposes libuv as vim.loop.
local uv = vim.uv or vim.loop

local PROTOCOL_VERSION = "2024-11-05"
local CLIENT_INFO = { name = "tai.nvim", version = "1.0.0" }

-- Pure Lua base64 (fallback when vim.base64 is unavailable).
local function b64encode(data)
	if vim.base64 and vim.base64.encode then
		return vim.base64.encode(data)
	end
	local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	return (
		(data:gsub(".", function(x)
			local r, byte = "", x:byte()
			for i = 8, 1, -1 do
				r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
			end
			return r
		end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
			if #x < 6 then
				return ""
			end
			local c = 0
			for i = 1, 6 do
				c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
			end
			return b:sub(c + 1, c + 1)
		end) .. ({ "", "==", "=" })[#data % 3 + 1]
	)
end

--- @class McpServerState
--- @field name string
--- @field config table
--- @field status string  -- "disconnected"|"connecting"|"connected"|"error"
--- @field error string|nil
--- @field tools table[]  -- {name, description, inputSchema}
--- @field job number|nil  -- job id for stdio
--- @field next_id number
--- @field pending table  -- id -> {callback, timer}
--- @field buf string      -- stdout buffer for stdio
--- @field server_info table|nil

local servers = {} -- name -> McpServerState

local function denylist_set(cfg)
	local set = {}
	if type(cfg.denylist) == "table" then
		for _, t in ipairs(cfg.denylist) do
			if type(t) == "string" then
				set[t] = true
			end
		end
	end
	return set
end

local function filter_tools(tools, cfg)
	local deny = denylist_set(cfg)
	local out = {}
	for _, t in ipairs(tools or {}) do
		if t and t.name and not deny[t.name] then
			table.insert(out, t)
		end
	end
	return out
end

local function auth_headers(cfg)
	local headers = {}
	if cfg.api_key and cfg.api_key ~= "" then
		table.insert(headers, "Authorization: Bearer " .. cfg.api_key)
		table.insert(headers, "X-Api-Key: " .. cfg.api_key)
	elseif cfg.user and cfg.pass then
		local token = b64encode(cfg.user .. ":" .. cfg.pass)
		table.insert(headers, "Authorization: Basic " .. token)
	elseif cfg.oauth_token and cfg.oauth_token ~= "" then
		table.insert(headers, "Authorization: Bearer " .. cfg.oauth_token)
	end
	if type(cfg.headers) == "table" then
		for k, v in pairs(cfg.headers) do
			table.insert(headers, tostring(k) .. ": " .. tostring(v))
		end
	end
	return headers
end

-- ── JSON-RPC helpers ──────────────────────────────────────────────

local function make_request(id, method, params)
	local req = {
		jsonrpc = "2.0",
		id = id,
		method = method,
	}
	if params ~= nil then
		req.params = params
	end
	return req
end

local function make_notification(method, params)
	local n = { jsonrpc = "2.0", method = method }
	if params ~= nil then
		n.params = params
	end
	return n
end

-- ── Stdio transport ───────────────────────────────────────────────

local function stdio_dispatch_line(state, line)
	if not line or line == "" then
		return
	end
	local ok, msg = pcall(vim.json.decode, line)
	if not ok or type(msg) ~= "table" then
		log.debug("[mcp:" .. state.name .. "] non-json line: " .. tostring(line):sub(1, 200))
		return
	end
	-- Response to our request
	if msg.id ~= nil and state.pending[msg.id] then
		local p = state.pending[msg.id]
		state.pending[msg.id] = nil
		if p.timer then
			pcall(function()
				p.timer:stop()
				p.timer:close()
			end)
		end
		if msg.error then
			local err_msg = msg.error
			if type(err_msg) == "table" then
				err_msg = err_msg.message or vim.json.encode(err_msg)
			end
			p.callback(nil, tostring(err_msg))
		else
			p.callback(msg.result, nil)
		end
		return
	end
	-- Server notifications/requests we ignore (no roots/sampling/list_changed)
	if msg.method then
		log.debug("[mcp:" .. state.name .. "] ignore server method: " .. tostring(msg.method))
	end
end

local function stdio_on_stdout(state, data)
	if not data then
		return
	end
	-- Neovim jobstart splits stdout on "\n". A trailing empty string means the
	-- chunk ended with a newline (previous element is a complete line). The last
	-- non-empty element without a following entry is a partial line.
	state.buf = state.buf or ""
	for i, chunk in ipairs(data) do
		if i < #data then
			-- Complete line (newline was the delimiter)
			local line = (state.buf .. (chunk or "")):gsub("\r$", "")
			state.buf = ""
			stdio_dispatch_line(state, line)
		else
			-- Last element: partial unless empty (empty => already handled above)
			if chunk and chunk ~= "" then
				state.buf = state.buf .. chunk
				-- Also accept a full JSON object without waiting for newline
				if state.buf:match("^%s*{") and state.buf:match("}%s*$") then
					local line = state.buf:gsub("\r$", "")
					state.buf = ""
					stdio_dispatch_line(state, line)
				end
			end
		end
	end
end

local function stdio_send(state, obj)
	if not state.job or state.job <= 0 then
		return false, "not connected"
	end
	local ok, encoded = pcall(vim.json.encode, obj)
	if not ok then
		return false, "encode failed"
	end
	local n = vim.fn.chansend(state.job, encoded .. "\n")
	if n == 0 then
		return false, "chansend failed"
	end
	return true
end

local function stdio_request(state, method, params, timeout_ms, callback)
	state.next_id = (state.next_id or 0) + 1
	local id = state.next_id
	local req = make_request(id, method, params)

	local done = false
	local function finish(result, err)
		if done then
			return
		end
		done = true
		callback(result, err)
	end

	local timer = uv.new_timer()
	state.pending[id] = { callback = finish, timer = timer }
	timer:start(timeout_ms or 15000, 0, vim.schedule_wrap(function()
		if state.pending[id] then
			state.pending[id] = nil
			finish(nil, "timeout waiting for " .. method)
		end
		pcall(function()
			timer:stop()
			timer:close()
		end)
	end))

	local ok, err = stdio_send(state, req)
	if not ok then
		state.pending[id] = nil
		pcall(function()
			timer:stop()
			timer:close()
		end)
		finish(nil, err)
	end
end

local function stdio_notify(state, method, params)
	return stdio_send(state, make_notification(method, params))
end

local function stdio_connect(state, on_done)
	local cfg = state.config
	local cmd = cfg.command
	if not cmd or cmd == "" then
		state.status = "error"
		state.error = "missing command"
		on_done(false, state.error)
		return
	end

	local args = { cmd }
	if type(cfg.args) == "table" then
		for _, a in ipairs(cfg.args) do
			table.insert(args, tostring(a))
		end
	end

	state.status = "connecting"
	state.buf = ""
	state.pending = {}
	state.next_id = 0

	-- jobstart expects env as a dict (map), not a list of "KEY=value" strings.
	-- When set, it replaces the process environment, so merge current env + overrides.
	local env = nil
	if type(cfg.env) == "table" then
		env = {}
		for k, v in pairs(vim.fn.environ()) do
			env[k] = tostring(v)
		end
		for k, v in pairs(cfg.env) do
			env[tostring(k)] = tostring(v)
		end
	end

	local job_opts = {
		rpc = false,
		stdin = "pipe",
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data, _)
			stdio_on_stdout(state, data)
		end,
		on_stderr = function(_, data, _)
			if not data then
				return
			end
			for _, line in ipairs(data) do
				if line and line ~= "" then
					log.debug("[mcp:" .. state.name .. " stderr] " .. line)
				end
			end
		end,
		on_exit = function(_, code, _)
			log.info(string.format("[mcp:%s] process exited code=%s", state.name, tostring(code)))
			state.job = nil
			if state.status == "connected" or state.status == "connecting" then
				state.status = "disconnected"
			end
			-- fail pending
			for id, p in pairs(state.pending) do
				state.pending[id] = nil
				if p.timer then
					pcall(function()
						p.timer:stop()
						p.timer:close()
					end)
				end
				p.callback(nil, "server exited")
			end
		end,
	}
	if env then
		job_opts.env = env
	end
	if cfg.cwd and cfg.cwd ~= "" then
		job_opts.cwd = cfg.cwd
	end

	local job = vim.fn.jobstart(args, job_opts)
	if job <= 0 then
		state.status = "error"
		state.error = "failed to start: " .. cmd
		on_done(false, state.error)
		return
	end
	state.job = job

	-- initialize handshake (empty capabilities object — no roots/sampling)
	local empty_caps = vim.empty_dict and vim.empty_dict() or setmetatable({}, { __jsontype = "object" })
	stdio_request(state, "initialize", {
		protocolVersion = PROTOCOL_VERSION,
		capabilities = empty_caps,
		clientInfo = CLIENT_INFO,
	}, 15000, function(result, err)
		if err then
			state.status = "error"
			state.error = err
			M.disconnect(state.name)
			on_done(false, err)
			return
		end
		state.server_info = result and result.serverInfo or result
		stdio_notify(state, "notifications/initialized", {})
		-- list tools
		stdio_request(state, "tools/list", {}, 15000, function(tools_result, tools_err)
			if tools_err then
				-- still mark connected; tools may be empty
				log.warning("[mcp:" .. state.name .. "] tools/list: " .. tools_err)
				state.tools = {}
			else
				local list = (tools_result and tools_result.tools) or {}
				state.tools = filter_tools(list, cfg)
			end
			state.status = "connected"
			state.error = nil
			log.info(string.format(
				"[mcp:%s] connected (stdio) tools=%d",
				state.name,
				#state.tools
			))
			on_done(true)
		end)
	end)
end

-- ── HTTP / remote transport ───────────────────────────────────────

local function http_post(url, headers, body_json, timeout_ms, callback)
	local tmp = vim.fn.tempname()
	local ok_w = pcall(vim.fn.writefile, { body_json }, tmp)
	if not ok_w then
		callback(nil, "failed to write temp body")
		return
	end

	local cmd = {
		"curl", "-s", "-S",
		"-X", "POST", url,
		"-H", "Content-Type: application/json",
		"-H", "Accept: application/json, text/event-stream",
		"--max-time", tostring(math.ceil((timeout_ms or 15000) / 1000)),
		"--data-binary", "@" .. tmp,
	}
	for _, h in ipairs(headers or {}) do
		table.insert(cmd, "-H")
		table.insert(cmd, h)
	end

	local response = ""
	local job = vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data then
				response = response .. table.concat(data, "\n")
			end
		end,
		on_stderr = function(_, data)
			if data then
				for _, line in ipairs(data) do
					if line ~= "" then
						log.debug("[mcp http stderr] " .. line)
					end
				end
			end
		end,
		on_exit = function(_, code)
			pcall(vim.fn.delete, tmp)
			if code ~= 0 then
				callback(nil, "curl exit " .. tostring(code) .. (response ~= "" and (": " .. response) or ""))
				return
			end
			-- Handle plain JSON or simple SSE data: lines
			local payload = response
			if payload:match("^event:") or payload:match("\ndata:") then
				local chunks = {}
				for line in payload:gmatch("[^\n]+") do
					local data = line:match("^data:%s*(.+)$")
					if data and data ~= "[DONE]" then
						table.insert(chunks, data)
					end
				end
				payload = table.concat(chunks, "")
			end
			if payload == "" then
				callback(nil, "empty response")
				return
			end
			local ok, parsed = pcall(vim.json.decode, payload)
			if not ok or type(parsed) ~= "table" then
				callback(nil, "invalid JSON response")
				return
			end
			callback(parsed, nil)
		end,
	})
	if job <= 0 then
		pcall(vim.fn.delete, tmp)
		callback(nil, "failed to start curl")
	end
end

local function http_request(state, method, params, timeout_ms, callback)
	state.next_id = (state.next_id or 0) + 1
	local id = state.next_id
	local req = make_request(id, method, params)
	local ok, body = pcall(vim.json.encode, req)
	if not ok then
		callback(nil, "encode failed")
		return
	end
	local headers = auth_headers(state.config)
	http_post(state.config.url, headers, body, timeout_ms, function(parsed, err)
		if err then
			callback(nil, err)
			return
		end
		if parsed.error then
			local e = parsed.error
			if type(e) == "table" then
				e = e.message or vim.json.encode(e)
			end
			callback(nil, tostring(e))
			return
		end
		callback(parsed.result, nil)
	end)
end

local function http_connect(state, on_done)
	local cfg = state.config
	if not cfg.url or cfg.url == "" then
		state.status = "error"
		state.error = "missing url"
		on_done(false, state.error)
		return
	end
	local oauth_url = cfg.oauthURL or cfg.oauth_url
	local oauth_token = cfg.oauth_token or cfg.oauthToken
	if oauth_url and (not oauth_token or oauth_token == "") then
		-- OAuth URL present but no token yet — leave disconnected with guidance
		state.status = "error"
		state.error = "oauthURL set but no oauth_token; complete OAuth and set oauth_token in config"
		on_done(false, state.error)
		return
	end
	-- Prefer explicit oauth_token for Bearer if provided without api_key
	if oauth_token and oauth_token ~= "" and (not cfg.api_key or cfg.api_key == "") then
		cfg = vim.tbl_extend("force", cfg, { oauth_token = oauth_token })
		state.config = cfg
	end

	state.status = "connecting"
	state.next_id = 0
	state.pending = {}

	local empty_caps = vim.empty_dict and vim.empty_dict() or setmetatable({}, { __jsontype = "object" })
	http_request(state, "initialize", {
		protocolVersion = PROTOCOL_VERSION,
		capabilities = empty_caps,
		clientInfo = CLIENT_INFO,
	}, 15000, function(result, err)
		if err then
			state.status = "error"
			state.error = err
			on_done(false, err)
			return
		end
		state.server_info = result and result.serverInfo or result
		-- best-effort initialized notification
		local notif = make_notification("notifications/initialized", {})
		local ok_e, body = pcall(vim.json.encode, notif)
		if ok_e then
			http_post(cfg.url, auth_headers(cfg), body, 5000, function() end)
		end
		http_request(state, "tools/list", {}, 15000, function(tools_result, tools_err)
			if tools_err then
				log.warning("[mcp:" .. state.name .. "] tools/list: " .. tools_err)
				state.tools = {}
			else
				local list = (tools_result and tools_result.tools) or {}
				state.tools = filter_tools(list, cfg)
			end
			state.status = "connected"
			state.error = nil
			log.info(string.format(
				"[mcp:%s] connected (http) tools=%d",
				state.name,
				#state.tools
			))
			on_done(true)
		end)
	end)
end

-- ── Public API ────────────────────────────────────────────────────

function M.get_servers()
	return servers
end

function M.get_server(name)
	return servers[name]
end

--- Configure servers from .tai `mcps` table (does not connect).
--- @param mcps table|nil map of name -> config
function M.configure(mcps)
	-- Drop servers no longer in config
	local keep = {}
	if type(mcps) == "table" then
		for name, cfg in pairs(mcps) do
			if type(cfg) == "table" then
				keep[name] = true
				if servers[name] then
					servers[name].config = cfg
				else
					servers[name] = {
						name = name,
						config = cfg,
						status = "disconnected",
						error = nil,
						tools = {},
						job = nil,
						next_id = 0,
						pending = {},
						buf = "",
						server_info = nil,
					}
				end
			end
		end
	end
	for name in pairs(servers) do
		if not keep[name] then
			M.disconnect(name)
			servers[name] = nil
		end
	end
end

function M.connect(name, on_done)
	on_done = on_done or function() end
	local state = servers[name]
	if not state then
		on_done(false, "unknown server: " .. tostring(name))
		return
	end
	if state.status == "connected" then
		on_done(true, "already connected")
		return
	end
	if state.status == "connecting" then
		on_done(false, "already connecting")
		return
	end

	local cfg = state.config
	if cfg.command then
		stdio_connect(state, on_done)
	elseif cfg.url then
		http_connect(state, on_done)
	else
		state.status = "error"
		state.error = "config needs command (local) or url (remote)"
		on_done(false, state.error)
	end
end

function M.disconnect(name)
	local state = servers[name]
	if not state then
		return false, "unknown server: " .. tostring(name)
	end
	for id, p in pairs(state.pending or {}) do
		state.pending[id] = nil
		if p.timer then
			pcall(function()
				p.timer:stop()
				p.timer:close()
			end)
		end
		if p.callback then
			p.callback(nil, "disconnected")
		end
	end
	if state.job and state.job > 0 then
		pcall(vim.fn.jobstop, state.job)
		state.job = nil
	end
	state.status = "disconnected"
	state.tools = {}
	state.error = nil
	state.buf = ""
	log.info("[mcp] disconnected: " .. name)
	return true, "disconnected: " .. name
end

--- Connect all configured servers (startup).
function M.connect_all(on_done)
	on_done = on_done or function() end
	local names = {}
	for name in pairs(servers) do
		table.insert(names, name)
	end
	if #names == 0 then
		on_done(true)
		return
	end
	local remaining = #names
	local function one()
		remaining = remaining - 1
		if remaining <= 0 then
			on_done(true)
		end
	end
	for _, name in ipairs(names) do
		M.connect(name, function()
			one()
		end)
	end
end

function M.disconnect_all()
	for name in pairs(servers) do
		M.disconnect(name)
	end
end

--- Call an MCP tool on a connected server.
function M.call_tool(server_name, tool_name, arguments, timeout_ms, callback)
	callback = callback or function() end
	local state = servers[server_name]
	if not state then
		callback(nil, "unknown server: " .. tostring(server_name))
		return
	end
	if state.status ~= "connected" then
		callback(nil, "server not connected: " .. server_name .. " (" .. state.status .. ")")
		return
	end
	local deny = denylist_set(state.config)
	if deny[tool_name] then
		callback(nil, "tool denied by denylist: " .. tool_name)
		return
	end

	local params = {
		name = tool_name,
		arguments = arguments or {},
	}

	local function handle(result, err)
		if err then
			callback(nil, err)
			return
		end
		-- Normalize MCP tool result content
		if type(result) == "table" and result.content then
			local parts = {}
			for _, c in ipairs(result.content) do
				if type(c) == "table" and c.type == "text" then
					table.insert(parts, c.text or "")
				elseif type(c) == "table" then
					table.insert(parts, vim.json.encode(c))
				end
			end
			local text = table.concat(parts, "\n")
			if result.isError then
				callback(nil, text ~= "" and text or "tool error")
			else
				callback(text, nil)
			end
		else
			local ok, enc = pcall(vim.json.encode, result)
			callback(ok and enc or tostring(result), nil)
		end
	end

	if state.config.command then
		stdio_request(state, "tools/call", params, timeout_ms or 60000, handle)
	else
		http_request(state, "tools/call", params, timeout_ms or 60000, handle)
	end
end

--- Synchronous-style call using vim.wait (for simpler tool runner paths).
function M.call_tool_sync(server_name, tool_name, arguments, timeout_ms)
	local done, result, err = false, nil, nil
	M.call_tool(server_name, tool_name, arguments, timeout_ms, function(r, e)
		result = r
		err = e
		done = true
	end)
	vim.wait(timeout_ms or 60000, function()
		return done
	end, 50)
	if not done then
		return nil, "timeout"
	end
	return result, err
end

function M.list_all_tools()
	local out = {}
	for name, state in pairs(servers) do
		if state.status == "connected" then
			for _, t in ipairs(state.tools or {}) do
				table.insert(out, {
					server = name,
					name = t.name,
					description = t.description or "",
					inputSchema = t.inputSchema,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if a.server == b.server then
			return a.name < b.name
		end
		return a.server < b.server
	end)
	return out
end

function M.status_text(name)
	if name and name ~= "" then
		local s = servers[name]
		if not s then
			return "unknown server: " .. name
		end
		local tool_names = {}
		for _, t in ipairs(s.tools or {}) do
			table.insert(tool_names, t.name)
		end
		return string.format(
			"%s: status=%s tools=[%s]%s",
			s.name,
			s.status,
			table.concat(tool_names, ", "),
			s.error and (" error=" .. s.error) or ""
		)
	end
	local names = {}
	for n in pairs(servers) do
		table.insert(names, n)
	end
	table.sort(names)
	if #names == 0 then
		return "No MCP servers configured. Add an `mcps` map to .tai"
	end
	local lines = { "MCP servers (" .. #names .. "):" }
	for _, n in ipairs(names) do
		local s = servers[n]
		local kind = s.config.command and "stdio" or (s.config.url and "http" or "?")
		table.insert(lines, string.format(
			"  %s [%s] %s — %d tools%s",
			s.name,
			s.status,
			kind,
			#(s.tools or {}),
			s.error and (" (" .. s.error .. ")") or ""
		))
		for _, t in ipairs(s.tools or {}) do
			table.insert(lines, string.format("    - %s: %s", t.name, t.description or ""))
		end
	end
	return table.concat(lines, "\n")
end

--- System prompt section: current MCP state + available tools (concise).
function M.render_prompt_section()
	local names = {}
	for n in pairs(servers) do
		table.insert(names, n)
	end
	if #names == 0 then
		return ""
	end
	table.sort(names)
	local lines = {
		"## MCP Servers",
		"Use the `mcp` tool to check status, connect/disconnect, or call server tools.",
	}
	for _, n in ipairs(names) do
		local s = servers[n]
		local tool_bits = {}
		for _, t in ipairs(s.tools or {}) do
			table.insert(tool_bits, t.name)
		end
		table.insert(lines, string.format(
			"- %s: %s%s",
			s.name,
			s.status,
			#tool_bits > 0 and (" tools: " .. table.concat(tool_bits, ", ")) or ""
		))
	end
	return table.concat(lines, "\n")
end

-- Cached tool schemas (set via update_tool_def from init); avoids mid-call requires.
local tool_defs = nil

--- Refresh the dynamic description of the mcp tool schema with live tools.
--- Pass defs once from setup; later calls may omit defs to refresh the cached table.
function M.update_tool_def(defs)
	if defs then
		tool_defs = defs
	end
	if not tool_defs or not tool_defs.mcp then
		return
	end
	local tools = M.list_all_tools()
	local desc_parts = {
		"Manage MCP servers and call their tools. Actions: status, connect, disconnect, list_tools, call.",
		"For call: provide server, tool, and arguments.",
	}
	if #tools > 0 then
		table.insert(desc_parts, "Currently available MCP tools:")
		for _, t in ipairs(tools) do
			table.insert(desc_parts, string.format(
				"- %s/%s: %s",
				t.server,
				t.name,
				t.description or ""
			))
		end
	else
		table.insert(desc_parts, "No MCP tools connected yet.")
	end
	tool_defs.mcp["function"].description = table.concat(desc_parts, "\n")
end

--- Tool handler for the `mcp` agent tool.
--- args: { action, server?, tool?, arguments? }
--- For call with async: pass on_done(result_string).
function M.run(args, on_done)
	args = args or {}
	local action = args.action

	local function finish(text)
		if on_done then
			on_done(text)
		end
		return text
	end

	if action == "status" then
		return finish(M.status_text(args.server))
	elseif action == "connect" then
		if not args.server or args.server == "" then
			return finish("Error: 'server' required for connect")
		end
		if on_done then
			M.connect(args.server, function(ok, err)
				if ok then
					M.update_tool_def()
					on_done(M.status_text(args.server))
				else
					on_done("Error connecting " .. args.server .. ": " .. tostring(err))
				end
			end)
			return nil -- async
		end
		local done, ok, err = false, false, nil
		M.connect(args.server, function(o, e)
			ok, err = o, e
			done = true
		end)
		vim.wait(20000, function()
			return done
		end, 50)
		if not done then
			return finish("Error: connect timeout")
		end
		if not ok then
			return finish("Error connecting " .. args.server .. ": " .. tostring(err))
		end
		M.update_tool_def()
		return finish(M.status_text(args.server))
	elseif action == "disconnect" then
		if not args.server or args.server == "" then
			return finish("Error: 'server' required for disconnect")
		end
		local ok, msg = M.disconnect(args.server)
		M.update_tool_def()
		return finish(ok and msg or ("Error: " .. msg))
	elseif action == "list_tools" then
		local tools = M.list_all_tools()
		if args.server and args.server ~= "" then
			local filtered = {}
			for _, t in ipairs(tools) do
				if t.server == args.server then
					table.insert(filtered, t)
				end
			end
			tools = filtered
		end
		if #tools == 0 then
			return finish("No tools available.")
		end
		local lines = {}
		for _, t in ipairs(tools) do
			local schema = ""
			if t.inputSchema then
				local ok, enc = pcall(vim.json.encode, t.inputSchema)
				if ok then
					schema = " schema=" .. enc
				end
			end
			table.insert(lines, string.format("%s/%s: %s%s", t.server, t.name, t.description or "", schema))
		end
		return finish(table.concat(lines, "\n"))
	elseif action == "call" then
		if not args.server or args.server == "" then
			return finish("Error: 'server' required for call")
		end
		if not args.tool or args.tool == "" then
			return finish("Error: 'tool' required for call")
		end
		local arguments = args.arguments or {}
		if type(arguments) == "string" then
			local ok, decoded = pcall(vim.json.decode, arguments)
			if ok and type(decoded) == "table" then
				arguments = decoded
			else
				return finish("Error: arguments must be a JSON object")
			end
		end
		if on_done then
			M.call_tool(args.server, args.tool, arguments, 60000, function(result, err)
				if err then
					on_done("Error: " .. err)
				else
					on_done(result or "(empty)")
				end
			end)
			return nil -- async
		end
		local result, err = M.call_tool_sync(args.server, args.tool, arguments, 60000)
		if err then
			return finish("Error: " .. err)
		end
		return finish(result or "(empty)")
	end
	return finish("Error: unknown action '" .. tostring(action) .. "'. Use status|connect|disconnect|list_tools|call")
end

function M._reset()
	M.disconnect_all()
	servers = {}
end

return M
