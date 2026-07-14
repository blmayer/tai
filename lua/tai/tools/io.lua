local M = {}
local log = require('tai.log')

-- Max characters returned from read/shell tools to the model (head+tail truncation).
M.MAX_TOOL_OUTPUT = 80000
M.MAX_NOTES_CHARS = 6000

--- Truncate oversized tool output before it is sent back to the agent.
--- Keeps head and tail so build/log errors near the end are still visible.
function M.limit_output(output, source)
	if type(output) ~= "string" then
		return output
	end
	local n = #output
	if n <= M.MAX_TOOL_OUTPUT then
		return output
	end
	local half = math.floor(M.MAX_TOOL_OUTPUT / 2)
	local head = output:sub(1, half)
	local tail = output:sub(n - half + 1)
	local msg = string.format(
		"\n\n[sys] Output truncated (%d chars > %d limit from %s). "
			.. "Showing head and tail. Prefer a narrower read range, grep, head/tail, or filters.\n\n"
			.. "--- tail ---\n",
		n,
		M.MAX_TOOL_OUTPUT,
		source or "tool"
	)
	log.warning(string.format(
		"Truncated %s output: %d chars (limit %d)",
		source or "tool",
		n,
		M.MAX_TOOL_OUTPUT
	))
	return head .. msg .. tail
end

-- indexes are 1 based
local function parse_lines(range)
	-- Handle "$" (last line)
	if range == "$" then
		return { -1, -1 }, true
	end

	-- Handle negative ranges (e.g., -5:$ for last 5 lines)
	local start, end_line = range:match("^(-%d+):%$")
	if start and end_line then
		return { tonumber(start), -1 }, true
	end

	-- Handle positive-to-$ ranges (e.g., 10:$ for tenth to last line)
	local dollar_pos = range:match("():%$")
	if dollar_pos and dollar_pos > 1 then
		local start_num = tonumber(range:sub(1, dollar_pos - 1))
		if start_num then
			return { start_num - 1, -1 }, true
		end
	end

	-- Handle range (e.g., "2:5")
	start, end_line = range:match("^(%d+):(%d+)$")
	if start and end_line then
		return { tonumber(start) - 1, tonumber(end_line) - 1 }, true
	end

	-- Handle single line (e.g., "3")
	local line = tonumber(range)
	if line == 0 then
		return { 0, 0 }, true
	end
	if line then
		return { line - 1, line - 1 }, true
	end

	return {}, false
end

local function is_binary_file(file_path)
	local file = io.open(file_path, "rb")
	if not file then return false end

	local content = file:read(8192) -- Read first 8KB
	file:close()

	-- Check for null bytes (strong indicator of binary)
	if not content then
		return false
	end

	for i = 1, #content do
		local byte = content:byte(i)
		if (byte < 9) then
			return true
		end
	end

	return false
end

function M.read_file(file_path, range)
	log.debug("Running read_file `" .. file_path .. "` with range: " .. (range or "nil"))

	if file_path:sub(1, 1) == "/" then
		return "Paths cannot start from root (/). Use relative."
	end

	-- Check if file is binary before attempting to read
	if is_binary_file(file_path) then
		return "Binary file detected. Use send_image for images or other binary formats."
	end

	-- Avoid loading enormous files fully into memory (freezes Neovim).
	-- Allow ranged reads up to a larger on-disk size; still truncate final output.
	local max_read_bytes = M.MAX_TOOL_OUTPUT * 4
	local stat = vim.uv.fs_stat(file_path)
	if stat and stat.size and stat.size > max_read_bytes and (not range or range == "") then
		log.warning(string.format(
			"read refused full file: %s is %d bytes (limit %d); use a range",
			file_path,
			stat.size,
			max_read_bytes
		))
		return string.format(
			"[sys] File `%s` is %d bytes (>%d). Refuse full read to protect context size. "
				.. "Pass a `range` (e.g. 1:200) or use shell grep/head/tail.",
			file_path,
			stat.size,
			max_read_bytes
		)
	end

	-- Always read from disk to ensure fresh content (buffers can be stale).
	log.debug("reading from file")
	local file = io.open(file_path, "r")
	if not file then
		return "File `" ..
		    file_path .. "` not found. Hint: check if it exists with the shell command: ls -R."
	end
	local content = file:read("*all")
	file:close()
	local lines = vim.split(content, '\n', { plain = true })

	local numbered_lines = {}
	if not range or range == "" then
		-- If no range is specified, return all lines
		for i, line in ipairs(lines) do
			table.insert(numbered_lines, string.format("%d: %s", i, line))
		end
	local numbered_content = table.concat(numbered_lines, "\n")
		return M.limit_output(numbered_content, "read:" .. file_path)
	end

	-- Parse the range (parse_lines returns 0-based indexes for patch usage)
	local int, ok = parse_lines(range)
	if not ok then
		return "Error: Invalid range " .. range
	end

	local start0 = int[1]
	local end0 = int[2]
	local nlines = #lines

	-- Convert negative indexes (relative to end) to 0-based absolute indexes
	if start0 < 0 then
		start0 = nlines + start0
	end
	if end0 < 0 then
		end0 = nlines + end0
	end

	-- Convert to 1-based for display
	local start1 = start0 + 1
	local end1 = end0 + 1

	-- Clamp end1 to valid range (allow exceeding file length)
	if end1 > nlines then
		end1 = nlines
	end

	if start1 < 1 or end1 < 0 or start1 > nlines or start1 > end1 then
		return "Error: Invalid range " .. range
	end

	for i = start1, end1 do
		table.insert(numbered_lines, string.format("%d: %s", i, lines[i]))
	end

	local numbered_content = table.concat(numbered_lines, "\n")
	return M.limit_output(numbered_content, "read:" .. file_path)
end

-- Export helper functions for other modules
M.parse_lines = parse_lines
M.is_binary_file = is_binary_file

return M
