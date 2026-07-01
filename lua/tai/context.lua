local M = {}
local log = require('tai.log')

-- Default configuration
M.default_config = {
  enabled = true,
  cache_dir = nil, -- when nil, use project root (config.root)
  auto_save = true,
  save_on_shutdown = true,
  file_name = ".tai-session.json"
}

-- Get XDG cache directory
local function get_xdg_cache_dir()
  local xdg_cache = os.getenv("XDG_CACHE_HOME")
  if xdg_cache and xdg_cache ~= "" then
    return xdg_cache
  end
  return (os.getenv("HOME") or "") .. "/.cache"
end

-- Ensure cache directory exists
function M.ensure_cache_dir(dir)
  local stat = vim.uv.fs_stat(dir)
  if stat and stat.type == "directory" then
    return true
  end

  local ok = vim.fn.mkdir(dir, "p")
  if ok == 0 then
    return false, "mkdir failed for " .. dir
  end
  return true
end

-- Get full path to context file
function M.get_context_path(config)
  config = config or M.default_config
  local file_name = config.file_name or M.default_config.file_name

  if config.cache_dir and config.cache_dir ~= "" then
    local ok, err = M.ensure_cache_dir(config.cache_dir)
    if not ok then
      log.warning("[persist] Failed to create cache directory: " .. (err or "unknown error"))
      return nil
    end
    local path = config.cache_dir .. "/" .. file_name
    log.debug("[persist] context path (cache_dir): " .. path)
    return path
  end

  -- Project-scoped session file (default; matches README)
  local tai_config = require("tai.config")
  if tai_config.root then
    local path = tai_config.root .. "/" .. file_name
    log.debug("[persist] context path (project root): " .. path)
    return path
  end

  -- Fallback to XDG cache
  local cache_dir = get_xdg_cache_dir() .. "/tai"
  local ok, err = M.ensure_cache_dir(cache_dir)
  if not ok then
    log.warning("[persist] Failed to create fallback cache dir: " .. (err or "unknown"))
    return nil
  end
  local path = cache_dir .. "/" .. file_name
  log.debug("[persist] context path (xdg fallback): " .. path)
  return path
end

-- Load context from disk
-- Returns state table or nil
function M.load(config)
  config = config or M.default_config
  if not config.enabled then
    log.info("[persist] load skipped: context.enabled is false")
    return nil
  end

  local context_path = M.get_context_path(config)
  if not context_path then
    log.warning("[persist] load aborted: could not determine context file path")
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
    log.warning("[persist] session file is empty: " .. context_path)
    return nil
  end

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    log.warning("[persist] failed to parse session file: " .. context_path)
    return nil
  end

  local planner_n = data.planner_history and #data.planner_history or 0
  local coder_n = data.coder_history and #data.coder_history or 0
  log.info(string.format(
    "[persist] loaded session: planner_msgs=%d coder_msgs=%d agent=%s todos=%d notes=%d bytes=%d saved_at=%s",
    planner_n,
    coder_n,
    tostring(data.current_agent),
    data.todos_store and #data.todos_store or 0,
    data.notes_store and #tostring(data.notes_store) or 0,
    #content,
    tostring(data.saved_at)
  ))
  return data
end

-- Save context to disk
-- state: { planner_history, coder_history, current_agent, last_ctx?, todos_store?, todos_next_id?, notes_store? }
function M.save(state, config)
  config = config or M.default_config
  if not config.enabled then
    log.debug("[persist] save skipped: context.enabled is false")
    return false
  end

  if type(state) ~= "table" then
    log.error("[persist] save failed: state must be a table")
    return false
  end

  local context_path = M.get_context_path(config)
  if not context_path then
    log.warning("[persist] save aborted: could not determine context file path")
    return false
  end

  local context_data = {
    planner_history = state.planner_history,
    coder_history = state.coder_history,
    current_agent = state.current_agent,
    last_ctx = state.last_ctx,
    todos_store = state.todos_store,
    todos_next_id = state.todos_next_id,
    notes_store = state.notes_store,
    -- Exact chat buffer text so restore shows previous messages, not just agent state
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
    "[persist] saved session to %s (%d bytes, planner=%d coder=%d agent=%s)",
    context_path,
    #json,
    state.planner_history and #state.planner_history or 0,
    state.coder_history and #state.coder_history or 0,
    tostring(state.current_agent)
  ))
  return true
end

-- Clear context file
function M.clear(config)
  config = config or M.default_config
  if not config.enabled then
    log.debug("[persist] clear skipped: context.enabled is false")
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
  else
    log.debug("[persist] clear: no file to remove at " .. context_path)
  end
end

-- Initialize with config
function M.setup(config)
  M.default_config = vim.tbl_extend("force", M.default_config, config or {})
  log.info(string.format(
    "[persist] setup: enabled=%s auto_save=%s save_on_shutdown=%s file_name=%s cache_dir=%s path=%s",
    tostring(M.default_config.enabled),
    tostring(M.default_config.auto_save),
    tostring(M.default_config.save_on_shutdown),
    tostring(M.default_config.file_name),
    tostring(M.default_config.cache_dir),
    tostring(M.get_context_path(M.default_config))
  ))
end

return M
