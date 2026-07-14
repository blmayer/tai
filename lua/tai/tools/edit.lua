local M = {}
local log = require('tai.log')
local tools_io = require("tai.tools.io")

-- Export helper functions from io module
M.parse_lines = tools_io.parse_lines
M.is_binary_file = tools_io.is_binary_file

local function normalize_whitespace(str)
	-- Use parentheses to force only the first return value from the final gsub.
	-- (gsub returns the string plus the replacement count; we only want the string.)
	return (str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Find all 0-based starting line numbers where the exact sequence of
-- (normalized) old_lines appears contiguously in the buffer lines.
-- This replaces the previous streaming/greedy matcher so that when the
-- first line of old_text occurs multiple times we still consider later
-- candidate alignments for the full block (instead of failing after the
-- first partial prefix match).
local function find_match_starts(lines, old_lines)
	if not old_lines or #old_lines == 0 then
		return {}
	end
	local norm_buf = {}
	for _, line in ipairs(lines) do
		table.insert(norm_buf, normalize_whitespace(line))
	end
	local norm_old = {}
	for _, line in ipairs(old_lines) do
		table.insert(norm_old, normalize_whitespace(line))
	end

	local starts = {}
	local n = #norm_buf
	local m = #norm_old
	for i = 1, n - m + 1 do
		local is_match = true
		for k = 1, m do
			if norm_buf[i + k - 1] ~= norm_old[k] then
				is_match = false
				break
			end
		end
		if is_match then
			table.insert(starts, i - 1) -- 0-based for nvim_buf_set_lines
		end
	end
	return starts
end

function M.edit(file, old_text, new_text, multi, config)
	log.debug("Running edit for: " .. file .. " with old_text: " .. (old_text or "nil"))

	if file:sub(1, 1) == "/" then
		return "Paths cannot start from root (/). Use relative."
	end

	-- Check if file exists
	if vim.fn.filereadable(file) ~= 1 then
		return "Error: File not found: " ..
		    file .. ". Hint: check if it exists with the shell command: ls -R."
	end

	-- Check if file is binary before attempting to edit
	if M.is_binary_file(file) then
		return "Binary file detected. Use send_image for images or other binary formats."
	end

	-- Reuse an already-open buffer for the file, otherwise open a new split.
	local abs_path = vim.fn.fnamemodify(file, ":p")
	local buf = nil
	local buf_reused = false
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			local bname = vim.api.nvim_buf_get_name(b)
			if bname == abs_path then
				buf = b
				buf_reused = true
				break
			end
		end
	end
	if buf_reused then
		-- Buffer already open — make sure it's showing in some window
		local win_found = false
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) == buf then
				win_found = true
				break
			end
		end
		if not win_found then
			vim.cmd("topleft vsplit")
			vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
		end
	else
		vim.cmd("topleft vnew " .. vim.fn.fnameescape(file))
		buf = vim.api.nvim_get_current_buf()
	end

	-- Get current state of buffer
	local new_lines = vim.split(new_text or "", '\n')
	if old_text and old_text ~= "" then
		local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local old_lines = vim.split(old_text or "", '\n')

		local matches = find_match_starts(current_lines, old_lines)

		if #matches == 0 then
			-- Only close the buffer if we opened a new one (don't kill a reused buffer)
			if not buf_reused then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
			-- Report how many lines of old_text matched before diverging,
			-- to help the caller narrow down what went wrong.
			local best_matched = 0
			local norm_buf = {}
			for _, line in ipairs(current_lines) do
				table.insert(norm_buf, normalize_whitespace(line))
			end
			local norm_old = {}
			for _, line in ipairs(old_lines) do
				table.insert(norm_old, normalize_whitespace(line))
			end
			for i = 1, #norm_buf do
				if norm_buf[i] == norm_old[1] then
					local count = 0
					for k = 1, #norm_old do
						if i + k - 1 <= #norm_buf and norm_buf[i + k - 1] == norm_old[k] then
							count = k
						else
							break
						end
					end
					if count > best_matched then
						best_matched = count
					end
				end
			end
			return string.format(
				"Error: could not find old_text block in file (after whitespace normalization). Best partial match: %d/%d lines.",
				best_matched, #old_lines
			)
		end

		if multi then
			-- Apply from bottom to top so earlier (smaller) line numbers stay valid
			-- while we edit later parts of the file.
			local starts = {}
			for _, s in ipairs(matches) do table.insert(starts, s) end
			table.sort(starts, function(a, b) return a > b end)
			for _, start0 in ipairs(starts) do
				local stop0 = start0 + #old_lines
				vim.api.nvim_buf_set_lines(buf, start0, stop0, false, new_lines)
			end
		else
			-- Non-multi: use the earliest match (first occurrence in file order).
			-- The full-block search (instead of the old streaming matcher) ensures
			-- that even if the first line of old_text appears earlier without a
			-- following full match, we still find a later correct alignment for the
			-- whole block.
			local start0 = matches[1]
			local stop0 = start0 + #old_lines
			vim.api.nvim_buf_set_lines(buf, start0, stop0, false, new_lines)
		end
	else
		vim.api.nvim_buf_set_lines(buf, 0, 0, false, new_lines)
	end

	-- Save the buffer to disk
	vim.api.nvim_buf_call(buf, function() vim.cmd("write!") end)

	return "Patched " .. file
end

return M
