local tai = {}

local uv = vim.loop
local sock_path = "/tmp/tai.sock"
local sock = nil
local response_callback = nil

-- returns header, body
local function read_until_blank_line(chunk)
  local i, j = chunk:find("\r?\n\r?\n")
  if i and j then
    return chunk:sub(1, i - 1), chunk:sub(j+1)
  else
    return chunk, ""
  end
end


local function parse_mime_header_name(header)
  local name = header:match('name="([^"]+)"')
  if name then
    return name
  else
    return nil
  end
end

local function parse_mime(raw)
  local result = {}

  local start, remaining = read_until_blank_line(raw)
  local boundary = start:match('Content%-Type:%s+multipart/mixed;%s+boundary="([^"]+)"')
  if not boundary then return nil, "No boundary found" end
  boundary = boundary:gsub("%-", "%%%-")
  print("[tai] boundary: " .. boundary)

  while 1 do
    local _, e = remaining:find("\r?\n?%-%-" .. boundary .. "%-?%-?\r?\n?")
    if not e then
      print("missing boundary")
      break
    end
    remaining = remaining:sub(e+1)
    if not remaining or remaining == "" then
      break
    end
    print("[tai] re: " .. remaining)

    local header, body = read_until_blank_line(remaining)
    if not header then
      return nil, "no header part"
    end

    local name = parse_mime_header_name(header)
    if not name then
      print("name not found in header")
      break
    end

    local s = body:find("\r?\n?%-%-" .. boundary .. "%-?%-?\r?\n?")
    if not s then
      print("no more boundaries")
      break
    end
    print("[tai] " .. name .. ": " .. body:sub(1, s))
    result[name] = body:sub(1, s)
  end

  return result, nil
end


-- Connect to the socket at startup
function tai.connect()
  sock = uv.new_pipe(false)
  sock:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("[tai] Could not connect to " .. sock_path .. ": " .. err, vim.log.levels.ERROR)
      end)
    return
    end
    vim.schedule(function()
	vim.notify("[tai] Connected to " .. sock_path)
    end)
  end)

  sock:read_start(function(err, chunk)
    if err then
      vim.schedule(function()
        vim.notify("[tai] Read error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    if not chunk then
      vim.schedule(function()
        vim.notify("[tai] empty response", vim.log.levels.WARN)
      end)
      return
    end

    local fields, err = parse_mime(chunk)
    if err then
      vim.schedule(function()
        vim.notify("[tai] Parse error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    if not fields or fields == {} then
      vim.schedule(function()
        vim.notify("[tai] Parse error: empty fields", vim.log.levels.ERROR)
      end)
      return
    end

    if response_callback then response_callback(fields) end
  end)
end

-- Create a custom command to prompt the user for input and run a command
vim.api.nvim_create_user_command("TaiApplyPatch", function(opts)
  vim.ui.input({ prompt = "Apply this patch? [y/N]" }, function(input)
    if input == "y" then
      -- Run the command to apply the patch
      vim.api.nvim_command("vert diffpatch %")
    else
      -- Do nothing if the user enters anything other than "y"
    end
  end)
end, { nargs = 0 })

function tai.show_response(fields)
  if not fields.text and not fields.patch then
    return
  end
  local lines = vim.split(fields.text .. fields.patch or "", "\n", { trimempty = true })

  vim.schedule(function()
    -- Create a new horizontal split
    vim.cmd("vnew")
    local new_win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_width(new_win, 40)

    -- Set buffer options to make it a scratch window
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].filetype = "tai-output"

    -- Insert content
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_command("au BufDelete <buffer> lua require('tai').apply_patch('"..fields.patch.."')")

    -- Optional: prevent accidental edits
    vim.bo[bufnr].modifiable = false
  end)
end

-- Get visual selection
local function get_visual_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")

  if not start_pos or not end_pos then
    return nil
  end

  local start_row = start_pos[1] - 1
  local start_col = start_pos[2]
  local end_row = end_pos[1] - 1
  local end_col = end_pos[2] + 1  -- inclusive

  if start_row > end_row or (start_row == end_row and start_col >= end_col) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
  if not lines or #lines == 0 then
    return nil
  end

  return table.concat(lines, "\n")
end

function tai.send_text(text)
  if not sock then
    vim.notify("[tai] Socket not connected", vim.log.levels.ERROR)
    return
  end

  sock:write(text .. "\n")
end

-- Replace visual selection with response
function tai.replace_visual()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[2] - 1, end_pos[2], false)
  local text = table.concat(lines, "\n")

  response_callback = function(response)
    vim.api.nvim_buf_set_lines(bufnr, start_pos[2] - 1, end_pos[2], false, vim.split(response, "\n"))
  end
  tai.send_text(text)
end

-- Append response at cursor (insert mode)
function tai.insert_response()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()

  local filename = vim.fn.expand("%:p")

  local location = string.format("line %d, column %d", row, col)
  local payload = string.format(
    "I'm edditing %s with cursor at %s, the current line content is (inside backticks): ```%s```. Please continue that line, send **ONLY** the new text, don't send commentary or instructions. Your response is appended to the end of the cursor.", filename, location, line)

  response_callback = function(response)
    -- In insert mode: insert each line at cursor
    local before = line:sub(1, col)
    local after  = line:sub(col + 1)
    local lines = vim.split(response.text, "\n", { plain = true })

    local insert_lines = {}
    if #lines == 1 then
      insert_lines = { before .. lines[1] .. after }
    else
      insert_lines[1] = before .. lines[1]
      for i = 2, #lines - 1 do
        table.insert(insert_lines, lines[i])
      end
      insert_lines[#insert_lines + 1] = lines[#lines] .. after
    end

    vim.schedule(function()
      vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, insert_lines)
      vim.api.nvim_win_set_cursor(0, { row, col + #response })
    end)
  end
  tai.send_text(payload)
end


function tai.prompt_input()
  vim.ui.input({ prompt = "Tai Input:" }, function(input)
    if input and input ~= "" then
      if sock then
	local filename = vim.fn.expand("%:p")                -- absolute path
	local preamble = string.format("I'm edditing %s, please consider:\n", filename)

	response_callback = tai.show_response
        tai.send_text(preamble .. input .. "\n")
      else
        vim.notify("[tai] Socket not connected", vim.log.levels.ERROR)
      end
    end
  end)
end

function tai.prompt_full_file()
  vim.ui.input({ prompt = "Tai Input (contextual):" }, function(input)
    if not input or input == "" then return end

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    local filename = vim.fn.expand("%:p")                -- absolute path
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1], cursor[2] + 1

    local location = string.format("line %d, column %d", row, col)

    local preamble = string.format("I'm edditing %s with cursor at %s, please consider my demand:\n", filename, location)
    local payload = preamble .. "\n" .. input .. "\n***\nFile content:\n\n" .. text

    if sock then
      response_callback = tai.show_response
      tai.send_text(payload .. "\n")
    else
      vim.notify("[tai] Socket not connected", vim.log.levels.ERROR)
    end
  end)
end

function tai.operator_send(type)
  -- Get visual range from operator-pending motion
  local start_pos = vim.api.nvim_buf_get_mark(0, "[")
  local end_pos = vim.api.nvim_buf_get_mark(0, "]")

  local start_row = start_pos[1] - 1
  local start_col = start_pos[2]
  local end_row = end_pos[1] - 1
  local end_col = end_pos[2] + 1 -- inclusive

  local lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
  if not lines or #lines == 0 then
    vim.notify("[tai] Motion selection was empty", vim.log.levels.WARN)
    return
  end

  local text = table.concat(lines, "\n")

  local filename = vim.fn.expand("%:p")
  local location = string.format("# From line %d, col %d to line %d, col %d",
    start_pos[1], start_pos[2] + 1, end_pos[1], end_pos[2] + 1)

  local preamble = string.format("I'm edditing %s at %s, consider the selection:\n", filename, location)

  response_callback = tai.show_response
  tai.send_text(preamble .. text)
end

function tai.operator_send_with_prompt(type)
  -- Get the selected text range (like operator_send)
  local start_pos = vim.api.nvim_buf_get_mark(0, "[")
  local end_pos = vim.api.nvim_buf_get_mark(0, "]")
  local start_row = start_pos[1] - 1
  local start_col = start_pos[2]
  local end_row = end_pos[1] - 1
  local end_col = end_pos[2] + 1 -- inclusive

  local lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
  local text = table.concat(lines, "\n")

  -- Prompt user for input, then send combined
  vim.ui.input({ prompt = "Tai Input:" }, function(input)
    if not input or input == "" then return end

    local filename = vim.fn.expand("%:p")
    local location = string.format("# From line %d, col %d to line %d, col %d",
    start_pos[1], start_pos[2] + 1, end_pos[1], end_pos[2] + 1)

    local payload = string.format("I'm edditing %s at %s, consider the selection:\n\n%s\n\nAnd the input:\n%s",
    filename, location, text, input)

    if sock then
      response_callback = tai.show_response
      tai.send_text(payload .. "\n")
    else
      vim.notify("[tai] Socket not connected", vim.log.levels.ERROR)
    end
  end)
end

tai.connect()

return tai

