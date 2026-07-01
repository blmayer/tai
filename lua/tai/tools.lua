local M = {}
local log = require('tai.log')
local config = require("tai.config")

-- In-memory stores for agent tools
M.todos_store = {}  -- list of {id, text, status}
M.todos_next_id = 1
M.notes_store = ""  -- single string notepad

-- Max characters returned from read/shell tools to the model (head+tail truncation).
-- Keeps requests within context limits and avoids freezing on huge outputs.
M.MAX_TOOL_OUTPUT = 80000

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

M.defs = {
	read = {
		type = "function",
		["function"] = {
			name = "read",
			description =
			"Use this to read a file's content, it will return the file's content or range if given. Line numbers are added.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the file to read. Relative to the project's folder."
					},
					range = {
						type = "string",
						description =
						"Optional range of lines to read, starts at 1, colon separated. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line; Negative numbers are counted from the end: -\\d:$: get last lines. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$; last 5 lines: -5:$.",
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	shell = {
		type = "function",
		["function"] = {
			name = "shell",
			description =
			"Use this tool when you need to run commands in a shell in the project's folder, use it for running builds, exploring the codebase etc. Use relative paths (don't start with /). Arguments, pipes (|), conditionals (||, &&), and chaining (;) are allowed. Redirects (>, >>, <, <<, 2>&1 etc.) are NOT allowed. Returns the stdout and stderr of the command.",
			parameters = {
				type = "object",
				properties = {
					command = {
						type = "string",
						description =
						"The pipeline to be interpreted by the shell in the user's machine. All paths are relative to the project's folder. Avoid redirections like >, >>, <, <<, 2>&1 etc. 2>&1 is added to the end of the command."
					}
				},
				additionalProperties = false,
				required = { "command" }
			}
		}
	},
	coder = {
		type = "function",
		["function"] = {
			name = "coder",
			description =
			"Call the coder agent (implementer with read/write access) to perform code changes. Pass a detailed prompt describing the tasks, plan, target files, and any context. This tool returns immediately with an ack message; the coder runs with its own independent history and will hand back via the planner tool when finished.",
			parameters = {
				type = "object",
				properties = {
					prompt = {
						type = "string",
						description =
						"Detailed instructions of what to implement, how to behave, what to look for and what is the task. And any other information that can help in the implementation.",
					},
				},
				additionalProperties = false,
				required = { "prompt" }
			}
		}
	},
	planner = {
		type = "function",
		["function"] = {
			name = "planner",
			description =
			"Call the planner agent (architect, read-only) typically at the end of a coding task to hand back a detailed report for review and coordination. Pass the summary of work done as the prompt. Returns immediately with an ack; planner uses its own history.",
			parameters = {
				type = "object",
				properties = {
					prompt = {
						type = "string",
						description =
						"Detailed report/summary for the planner: files changed, specific edits, verification performed, issues found, etc. This becomes the handoff message the planner sees.",
					},
				},
				additionalProperties = false,
				required = { "prompt" }
			}
		}
	},
	send_image = {
		type = "function",
		["function"] = {
			name = "send_image",
			description =
			"Use this tool to send images to the agent so it can see and interpret screenshots, diagrams, UI mockups, error messages, or any visual content. Make sure you select the correct image file.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the image file to send. Relative to the project's folder."
					},
					prompt = {
						type = "string",
						description = "Optional prompt to guide what to look for in the image."
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	write = {
		type = "function",
		["function"] = {
			name = "write",
			description =
			"Use this to create new files with the given content. Ensures parent directories exist.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to create, relative to project folder"
					},
					content = {
						type = "string",
						description = "Content to write to the file"
					}
				},
				additionalProperties = false,
				required = { "file", "content" }
			}
		}
	},
	edit = {
		type = "function",
		["function"] = {
			name = "edit",
			description =
			"Use this to edit existing files by providing the old content changed. If old_text is empty, changes are made at the start of the file. Matching uses line-by-line comparison after normalizing whitespace (collapse runs of spaces, trim). If the first line of old_text appears multiple times, the matcher tries all possible alignments until the full old_text block matches.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to edit, relative to project folder"
					},
					old_text = {
						type = "string",
						description =
						"Content to be changed. Empty means start of file. This must match exactly (after per-line whitespace normalization). Use the MINIMUM number of context lines needed to uniquely identify the location — typically 1-3 distinctive lines, not large blocks. Don't add line numbers that appear on the read output, they are just for reference."
					},
					new_text = {
						type = "string",
						description = "New content to replace old_text in the file."
					},
					multi = {
						type = "boolean",
						description = "If true, replace every matching occurrence of the old_text block (instead of only the first match). Use when the same change should be applied in multiple places."
					}
				},
				additionalProperties = false,
				required = { "file", "old_text", "new_text" }
			}
		}
	},
	todos = {
		type = "function",
		["function"] = {
			name = "todos",
			description =
			"In-memory todo list to track progress on multi-step tasks. Use for tasks with 3+ steps. Actions: 'add' creates a new item, 'update' changes status/text of an existing item, 'list' returns all items.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "The action to perform: 'add', 'update', or 'list'.",
						enum = { "add", "update", "list" }
					},
					text = {
						type = "string",
						description = "Description of the todo item. Required for 'add', optional for 'update' (to change text)."
					},
					id = {
						type = "number",
						description = "ID of the todo item. Required for 'update'."
					},
					status = {
						type = "string",
						description = "Status of the item. For 'add' defaults to 'pending'. For 'update' changes the status.",
						enum = { "pending", "in_progress", "done", "cancelled" }
					}
				},
				additionalProperties = false,
				required = { "action" }
			}
		}
	},
	notes = {
		type = "function",
		["function"] = {
			name = "notes",
			description =
			"In-memory scratchpad for registering discoveries, important thoughts, decisions, and context gathered during the task. Use this to persist insights across tool calls so you don't lose track. Actions: 'read' returns current notes, 'write' overwrites with new content, 'append' adds to existing notes.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "The action: 'read', 'write', or 'append'.",
						enum = { "read", "write", "append" }
					},
					content = {
						type = "string",
						description = "The content to write or append. Required for 'write' and 'append'."
					}
				},
				additionalProperties = false,
				required = { "action" }
			}
		}
	},
}

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

function M.unsafe_command(cmd)
	log.debug("Running `" .. cmd .. "`")

	-- Check for disallowed redirect operators
	if cmd:match('[><]') then
		log.debug("Command contains redirects, which are not allowed: " .. cmd)
		return "[sys] Redirects (>, <, >>, <<, etc.) are not allowed."
	end

	local allowed = config.get_allowed_commands()

	-- Extract the base command (first word)
	local base_cmd = cmd:match("^%s*(%w+)")
	if not base_cmd and allowed[base_cmd] then
		return "Command " .. base_cmd .. " is not allowed."
	end

	return false
end

function M.exec_command(cmd)
	log.debug("Executing `" .. cmd .. "`")

	local env = {}
	for _, name in ipairs({ "PATH" }) do
		env[#env + 1] = name .. "=" .. (os.getenv(name) or "")
	end

	local env_prefix = ""
	for _, v in ipairs(env) do
		local name, value = v:match("^([^=]+)=(.*)$")
		if name and value then
			env_prefix = env_prefix .. name .. "='" .. value:gsub("'", "'\\\\'") .. "' "
		end
	end

	local full_cmd = env_prefix .. cmd .. " 2>&1"
	local handle = io.popen(full_cmd, "r")
	if not handle then
		return nil, "Failed to run command"
	end

local output = handle:read("*a")
	handle:close()

	if not output then
		output = cmd .. "` returned null"
	end

	return M.limit_output(output, "shell")
end

-- Convert image file to base64 data URL
function M.image_data_url(image_path)
	-- Check if file exists
	if vim.fn.filereadable(image_path) ~= 1 then
		return nil, "Image file not found: " .. image_path
	end

	-- Detect MIME type from extension
	local ext = image_path:match("%.(%w+)$")
	if not ext then
		return nil, "File has no extension, cannot determine image type"
	end
	local mime_types = {
		png = "image/png",
		jpg = "image/jpeg",
		jpeg = "image/jpeg",
		gif = "image/gif",
		webp = "image/webp",
		bmp = "image/bmp",
	}
	local mime = mime_types[ext:lower()]
	if not mime then
		return nil, "Unsupported image format: " .. ext .. ". Supported formats: png, jpg, jpeg, gif, webp, bmp."
	end

	-- Read file and encode to base64 using curl
	local cmd = string.format("base64 -i '%s' | tr -d '\n'", image_path)
	local handle = io.popen(cmd, "r")
	if not handle then
		return nil, "Failed to read image file"
	end
	local base64_content = handle:read("*a")
	handle:close()

	if not base64_content or #base64_content == 0 then
		return nil, "Failed to encode image to base64"
	end

	return "data:" .. mime .. ";base64," .. base64_content, nil
end

function M.write(file, content)
	log.debug("Running write_file for: " .. file)

	if file:sub(1, 1) == "/" then
		return "Paths cannot start from root (/). Use relative."
	end

	-- Ensure parent directory exists
	local dir = vim.fn.fnamemodify(file, ":p:h")
	if dir and dir ~= "" and dir ~= "." and vim.fn.isdirectory(dir) == 0 then
		local mkdir_result = vim.fn.mkdir(dir, "p")
		if mkdir_result == -1 then
			return "[sys] Error: Could not create directory: " .. dir
		end
	end

	-- Write content to file
	local f = io.open(file, "w")
	if not f then
		return "Error: Could not open file for writing: " .. file
	end
	f:write(content)
	f:close()

	return "File created: " .. file
end

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

function M.edit(file, old_text, new_text, multi)
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
	if is_binary_file(file) then
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

function M.run_todos(args)
	local action = args.action
	if action == "add" then
		if not args.text or args.text == "" then
			return "Error: 'text' is required for 'add'"
		end
		local item = {
			id = M.todos_next_id,
			text = args.text,
			status = args.status or "pending",
		}
		table.insert(M.todos_store, item)
		M.todos_next_id = M.todos_next_id + 1
		return string.format("Added todo #%d: [%s] %s", item.id, item.status, item.text)
	elseif action == "update" then
		if not args.id then
			return "Error: 'id' is required for 'update'"
		end
		for _, item in ipairs(M.todos_store) do
			if item.id == args.id then
				if args.status then item.status = args.status end
				if args.text then item.text = args.text end
				return string.format("Updated todo #%d: [%s] %s", item.id, item.status, item.text)
			end
		end
		return "Error: todo #" .. tostring(args.id) .. " not found"
	elseif action == "list" then
		if #M.todos_store == 0 then
			return "No todos yet."
		end
		local lines = {}
		for _, item in ipairs(M.todos_store) do
			table.insert(lines, string.format("#%d [%s] %s", item.id, item.status, item.text))
		end
		return table.concat(lines, "\n")
	else
		return "Error: unknown action '" .. tostring(action) .. "'"
	end
end

function M.run_notes(args)
	local action = args.action
	if action == "read" then
		if M.notes_store == "" then
			return "(empty)"
		end
		return M.notes_store
	elseif action == "write" then
		if not args.content then
			return "Error: 'content' is required for 'write'"
		end
		M.notes_store = args.content
		return "Notes updated: " .. args.content
	elseif action == "append" then
		if not args.content then
			return "Error: 'content' is required for 'append'"
		end
		if M.notes_store == "" then
			M.notes_store = args.content
		else
			M.notes_store = M.notes_store .. "\n" .. args.content
		end
		return "Note appended: " .. args.content
	end
	return "Error: unknown action '" .. tostring(action) .. "'"
end

return M
