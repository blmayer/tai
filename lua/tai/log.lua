local M = {}

-- Log levels
M.DEBUG = 1
M.INFO = 2
M.WARNING = 3
M.ERROR = 4

-- Current log level (default to INFO)
M.level = M.INFO

-- Use XDG cache directory for logs
local function get_xdg_cache_dir()
  local xdg_cache = os.getenv("XDG_CACHE_HOME")
  if xdg_cache and xdg_cache ~= "" then
    return xdg_cache
  end
  return os.getenv("HOME") .. "/.cache"
end
M.log_file = get_xdg_cache_dir() .. "/tai.log"

-- Set the log level
function M.set_level(level)
	M.level = level
end

-- Set the log file path
function M.set_log_file(path)
	M.log_file = path
end

-- Log a message
function M.log(level, message)
	if level >= M.level then
		local level_str
		if level == M.DEBUG then
			level_str = "DEBUG"
		elseif level == M.INFO then
			level_str = "INFO"
		elseif level == M.WARNING then
			level_str = "WARNING"
		elseif level == M.ERROR then
			level_str = "ERROR"
		end

		local timestamp = os.date("%Y-%m-%d %H:%M:%S")
		local log_message = string.format("[%s] [%s] %s", timestamp, level_str, message)

		local file = io.open(M.log_file, "a")
		if file then
			file:write(log_message .. "\n")
			file:close()
		end
	end
end

-- Convenience functions for different log levels
function M.debug(message)
	M.log(M.DEBUG, message)
end

function M.info(message)
	M.log(M.INFO, message)
end

function M.warning(message)
	M.log(M.WARNING, message)
end

function M.error(message)
	M.log(M.ERROR, message)
end

return M
