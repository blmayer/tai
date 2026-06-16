local M = {}
local log = require('tai.log')

-- Default configuration
M.default_config = {
  enabled = true,
  cache_dir = nil, -- will be set to XDG_CACHE_HOME or ~/.cache
  auto_save = true,
  save_on_shutdown = true,
  file_name = "tai_context.json"
}

-- Get XDG cache directory
local function get_xdg_cache_dir()
  -- Check XDG_CACHE_HOME environment variable
  local xdg_cache = os.getenv("XDG_CACHE_HOME")
  if xdg_cache and xdg_cache ~= "" then
    return xdg_cache
  end
  -- Default to ~/.cache
  return os.getenv("HOME") .. "/.cache"
end

-- Get full path to context file
function M.get_context_path(config)
  local cache_dir = config.cache_dir or get_xdg_cache_dir()
  -- Ensure cache directory exists
  local ok, err = M.ensure_cache_dir(cache_dir)
  if not ok then
    log.warning("Failed to create cache directory: " .. (err or "unknown error"))
    return nil
  end
  return cache_dir .. "/" .. config.file_name
end

-- Ensure cache directory exists
function M.ensure_cache_dir(dir)
  local stat = vim.uv.fs_stat(dir)
  if stat and stat.type == "directory" then
    return true
  end
  
  -- Try to create directory
  local ok, err = vim.fn.mkdir(dir, "p")
  if not ok then
    return false, err
  end
  return true
end

-- Load context from disk
-- Returns: { planner_history, coder_history, current_agent, last_ctx } or nil
function M.load(config)
  if not config or not config.enabled then
    log.debug("Context loading disabled")
    return nil
  end

  local context_path = M.get_context_path(config)
  if not context_path then
    log.warning("Could not determine context file path")
    return nil
  end

  local file = io.open(context_path, "r")
  if not file then
    log.debug("No existing context file found at: " .. context_path)
    return nil
  end

  local content = file:read("*a")
  file:close()

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    log.warning("Failed to parse context file, creating new context")
    return nil
  end

  log.info("Loaded context from: " .. context_path)
  return data
end

-- Save context to disk
function M.save(planner_history, coder_history, current_agent, last_ctx, config)
  if not config or not config.enabled then
    log.debug("Context saving disabled")
    return
  end

  local context_path = M.get_context_path(config)
  if not context_path then
    log.warning("Could not determine context file path")
    return
  end

  local context_data = {
    planner_history = planner_history,
    coder_history = coder_history,
    current_agent = current_agent,
    last_ctx = last_ctx,
    saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ") -- ISO 8601 UTC
  }

  local json = vim.fn.json_encode(context_data)
  local file = io.open(context_path, "w")
  if not file then
    log.error("Failed to open context file for writing: " .. context_path)
    return
  end

  file:write(json)
  file:close()

  log.info("Context saved to: " .. context_path)
end

-- Clear context file
function M.clear(config)
  if not config or not config.enabled then
    return
  end

  local context_path = M.get_context_path(config)
  if not context_path then
    return
  end

  local ok, err = os.remove(context_path)
  if ok then
    log.info("Context cleared: " .. context_path)
  elseif err and not err:match("cannot remove") then
    log.warning("Failed to clear context: " .. (err or "unknown error"))
  end
end

-- Initialize with config
function M.setup(config)
  M.default_config = vim.tbl_extend("force", M.default_config, config or {})
end

return M