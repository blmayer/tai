local tai = {}

local uv = vim.loop
local sock_path = "/tmp/tai.sock"
local sock = nil

local function parse_mime(mime_text)
  local parts = {}
  local boundary = mime_text:match("boundary=\"?([^\"]+)\"?")
  if not boundary then return parts end

  -- Split the entire message into parts using boundary
  for part in mime_text:gmatch("--" .. boundary .. "%s*(.-)%s*--" .. boundary .. "[%s%-]*") do
    local headers = {}
    local body = part:match("\r?\n\r?\n(.*)")
    local header_section = part:match("^(.-)\r?\n\r?\n")

    if header_section then
      for name, value in header_section:gmatch("([%w%-]+):%s*(.-)\r?\n") do
        headers[name:lower()] = value
      end

      -- Try to get a name (e.g., from Content-Disposition or Content-Type)
      local name = headers["content-disposition"] and headers["content-disposition"]:match('filename="?(.-)"?')

      if name and body then
        parts[name] = body:gsub("\r\n", "\n") -- normalize line endings
      end
    end
  end

  return parts
end

local function parse_named_mime_fields(raw)
  local result = {}

  -- Extract the boundary
  local boundary = raw:match("boundary=\"?([^\"]+)\"?")
  if not boundary then return nil, "No boundary found" end
  boundary = "--" .. boundary
      vim.schedule(function()
	  vim.notify("boundary " .. boundary)
  end)

  -- Split parts
  for part in raw:gmatch(boundary .. "\r?\n(.-)\r?\n" .. boundary) do
      vim.schedule(function()
	  vim.notify("part " .. part)
  end)
    local headers, body = part:match("^(.-)\r?\n\r?\n(.*)")
    if headers and body then
      local name = headers:match('filename="([^"]+)"')
      if name then
        -- Remove any trailing boundary marker
        body = body:gsub("\r?\n$", "")
        result[name] = body
      end
    end
  end

      vim.schedule(function()
        vim.notify("[tai] parsed text " .. result.text, vim.log.levels.INFO)
        vim.notify("[tai] parsed patch " .. result.patch, vim.log.levels.INFO)
       end)
  return result
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
    return
  end)

  sock:read_start(function(err, chunk)
    if err then
      vim.schedule(function()
        vim.notify("[tai] Read error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    if not chunk then
      return
    end

    local fields, err = parse_named_mime_fields(chunk)
    if err then
      vim.schedule(function()
        vim.notify("[tai] Parse error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    if fields.text then
      vim.schedule(function()
          tai.show_output_in_split(fields.text)
      end)
    end
    if fields.patch then
      vim.schedule(function()
          tai.show_output_in_vsplit(fields.patch)
      end)
    end
  end)
end

function tai.show_output_in_split(content)
  local lines = vim.split(content or "", "\n", { trimempty = true })

  -- Create a new horizontal split
  vim.cmd("botright 8new")
  local bufnr = vim.api.nvim_get_current_buf()

  -- Set buffer options to make it a scratch window
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "tai-output"

  -- Insert content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Optional: prevent accidental edits
  vim.bo[bufnr].modifiable = false
end

function tai.show_output_in_vsplit(content)
  local lines = vim.split(content or "", "\n", { trimempty = true })

  -- Create a new vertical split
  vim.cmd("vnew")
  local bufnr = vim.api.nvim_get_current_buf()

  -- Set buffer options to make it a scratch window
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "tai-output"

  -- Insert content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Optional: prevent accidental edits
  vim.bo[bufnr].modifiable = false
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

function tai.prompt_input()
  vim.ui.input({ prompt = "Tai Input:" }, function(input)
    if input and input ~= "" then
      if sock then
	local filename = vim.fn.expand("%:p")                -- absolute path
	local preamble = string.format("I'm edditing %s, please consider:\n", filename)
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
    local filetype = vim.bo.filetype
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1], cursor[2] + 1

    local location = string.format("line %d, column %d", row, col)

    local preamble = string.format("I'm edditing %s with cursor at %s, please consider my demand:\n", filename, location)
    local payload = preamble .. "\n" .. input .. "\n***\nFile content:\n\n" .. text

    if sock then
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
      tai.send_text(payload .. "\n")
    else
      vim.notify("[tai] Socket not connected", vim.log.levels.ERROR)
    end
  end)
end

tai.connect()

return tai

