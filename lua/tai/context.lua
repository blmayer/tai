local M = {}
local log = require("tai.log")

M.default_config = {
	enabled = true,
	cache_dir = nil,
	auto_save = true,
	save_on_shutdown = true,
	file_name = ".tai-session.json",
}

local function get_xdg_cache_dir()
	local xdg_cache = os.getenv("XDG_CACHE_HOME")
	if xdg_cache and xdg_cache ~= "" then
		return xdg_cache
	end
	return (os.getenv("HOME") or "") .. "/.cache"
end

function M.ensure_cache_dir(dir)
	local stat = vim.uv.fs_stat(dir)
	if stat and stat.type == "directory" then
		return true
	end
	if vim.fn.mkdir(dir, "p") == 0 then
		return false, "mkdir failed for " .. dir
	end
	return true
end

function M.get_context_path(config)
	config = config or M.default_config
	local file_name = config.file_name or M.default_config.file_name

	if config.cache_dir and config.cache_dir ~= "" then
		local ok, err = M.ensure_cache_dir(config.cache_dir)
		if not ok then
			log.warning("[persist] Failed to create cache directory: " .. (err or "unknown error"))
			return nil
		end
		return config.cache_dir .. "/" .. file_name
	end

	local tai_config = require("tai.config")
	if tai_config.root then
		return tai_config.root .. "/" .. file_name
	end

	local cache_dir = get_xdg_cache_dir() .. "/tai"
	local ok, err = M.ensure_cache_dir(cache_dir)
	if not ok then
		log.warning("[persist] Failed to create fallback cache dir: " .. (err or "unknown"))
		return nil
	end
	return cache_dir .. "/" .. file_name
end

function M.load(config)
	config = config or M.default_config
	if not config.enabled then
		return nil
	end

	local context_path = M.get_context_path(config)
	if not context_path then
		return nil
	end

	log.info("[persist] loading from: " .. context_path)
	local file = io.open(context_path, "r")
	if not file then
		log.info("[persist] no existing session file at: " .. context_path)
		return nil
	end

	local content = file:read("*a")
	file:close()
	if not content or content == "" then
		return nil
	end

	local ok, data = pcall(vim.fn.json_decode, content)
	if not ok or type(data) ~= "table" then
		log.warning("[persist] failed to parse session file: " .. context_path)
		return nil
	end

	local n = data.stack and #data.stack or 0
	log.info(string.format(
		"[persist] loaded session: frames=%d bytes=%d saved_at=%s",
		n,
		#content,
		tostring(data.saved_at)
	))
	return data
end

--- state: { stack, last_ctx?, chat_lines? } (legacy planner/coder fields also accepted on load)
function M.save(state, config)
	config = config or M.default_config
	if not config.enabled then
		return false
	end
	if type(state) ~= "table" then
		log.error("[persist] save failed: state must be a table")
		return false
	end

	local context_path = M.get_context_path(config)
	if not context_path then
		return false
	end

	local context_data = {
		stack = state.stack,
		last_ctx = state.last_ctx,
		chat_lines = state.chat_lines,
		saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}

	local ok_enc, json = pcall(vim.fn.json_encode, context_data)
	if not ok_enc or type(json) ~= "string" then
		log.error("[persist] save failed: json_encode error: " .. tostring(json))
		return false
	end

	local file = io.open(context_path, "w")
	if not file then
		log.error("[persist] failed to open for writing: " .. context_path)
		return false
	end
	file:write(json)
	file:close()

	log.info(string.format(
		"[persist] saved session to %s (%d bytes, frames=%d)",
		context_path,
		#json,
		state.stack and #state.stack or 0
	))
	return true
end

function M.clear(config)
	config = config or M.default_config
	if not config.enabled then
		return
	end
	local context_path = M.get_context_path(config)
	if not context_path then
		return
	end
	local ok, err = os.remove(context_path)
	if ok then
		log.info("[persist] cleared session file: " .. context_path)
	elseif err and not tostring(err):match("No such file") and not tostring(err):match("cannot remove") then
		log.warning("[persist] failed to clear session: " .. tostring(err))
	end
end

function M.setup(config)
	M.default_config = vim.tbl_extend("force", M.default_config, config or {})
	log.info(string.format(
		"[persist] setup: enabled=%s path=%s",
		tostring(M.default_config.enabled),
		tostring(M.get_context_path(M.default_config))
	))
end

return M
