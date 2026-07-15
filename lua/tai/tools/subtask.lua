local M = {}
local log = require("tai.log")

function M.format_todos(todos)
	if not todos or #todos == 0 then
		return "(none)"
	end
	local lines = {}
	for _, item in ipairs(todos) do
		table.insert(lines, string.format("#%d [%s] %s", item.id, item.status, item.text))
	end
	return table.concat(lines, "\n")
end

--- Truncate notes for injection (head + tail).
function M.format_notes(notes, max_chars)
	notes = notes or ""
	if notes == "" then
		return ""
	end
	max_chars = max_chars or 6000
	if #notes <= max_chars then
		return notes
	end
	local half = math.floor(max_chars / 2)
	return notes:sub(1, half)
		.. "\n\n[notes truncated]\n\n"
		.. notes:sub(#notes - half + 1)
end

--- Live context injected into the system prompt each request (never stored in history).
--- Returns "" when empty so callers can skip injection.
function M.render_memory(frame)
	local parts = {}
	if frame.todos and #frame.todos > 0 then
		table.insert(parts, "## Current Todos\n" .. M.format_todos(frame.todos))
	end
	local notes = M.format_notes(frame.notes)
	if notes ~= "" then
		table.insert(parts, "## Notes\n" .. notes)
	end
	if #parts == 0 then
		return ""
	end
	return "--- Live Context (updated every turn, not part of history) ---\n"
		.. table.concat(parts, "\n\n")
		.. "\n--- End Live Context ---"
end

--- Payload returned to parent when a subtask finishes (final text + child memory).
function M.format_complete(status, summary, frame)
	return table.concat({
		"status: " .. (status or "ok"),
		"summary: " .. (summary or "(no output)"),
		"",
		"## Subtask notes",
		(frame.notes and frame.notes ~= "" and frame.notes) or "(empty)",
		"",
		"## Subtask todos",
		M.format_todos(frame.todos),
	}, "\n")
end

--- @param args table
--- @param frame table agent frame with todos / todos_next_id
function M.run_todos(args, frame)
	local action = args.action
	if action == "add" then
		if not args.text or args.text == "" then
			return "Error: 'text' is required for 'add'"
		end
		local item = {
			id = frame.todos_next_id,
			text = args.text,
			status = args.status or "pending",
		}
		table.insert(frame.todos, item)
		frame.todos_next_id = frame.todos_next_id + 1
		return string.format("Added todo #%d: [%s] %s", item.id, item.status, item.text)
	elseif action == "update" then
		if not args.id then
			return "Error: 'id' is required for 'update'"
		end
		for _, item in ipairs(frame.todos) do
			if item.id == args.id then
				if args.status then
					item.status = args.status
				end
				if args.text then
					item.text = args.text
				end
				return string.format("Updated todo #%d: [%s] %s", item.id, item.status, item.text)
			end
		end
		return "Error: todo #" .. tostring(args.id) .. " not found"
	end
	return "Error: unknown action '" .. tostring(action) .. "'"
end

--- @param args table
--- @param frame table agent frame with notes string
function M.run_notes(args, frame)
	local action = args.action
	if action == "write" then
		if not args.content then
			return "Error: 'content' is required for 'write'"
		end
		frame.notes = args.content
		return string.format("Notes updated (%d chars).", #args.content)
	elseif action == "append" then
		if not args.content then
			return "Error: 'content' is required for 'append'"
		end
		if frame.notes == "" then
			frame.notes = args.content
		else
			frame.notes = frame.notes .. "\n" .. args.content
		end
		return string.format("Notes appended (%d chars).", #args.content)
	end
	return "Error: unknown action '" .. tostring(action) .. "'"
end

-- Add write function
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

-- Add image_data_url function
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

return M
