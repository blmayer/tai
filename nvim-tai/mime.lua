local M = {}

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

function M.parse(raw)
  local result = {}

  local start, remaining = read_until_blank_line(raw)
  local boundary = start:match('Content%-Type:%s+multipart/mixed;%s+boundary="([^"]+)"')
  if not boundary then return nil, "No boundary found" end
  boundary = boundary:gsub("%-", "%%%-")

  while 1 do
    local _, e = remaining:find("\r?\n?%-%-" .. boundary .. "%-?%-?\r?\n?")
    if not e then
      break
    end
    remaining = remaining:sub(e+1)
    if not remaining or remaining == "" then
      break
    end

    local header, body = read_until_blank_line(remaining)
    if not header then
      return nil, "no header part"
    end

    local name = parse_mime_header_name(header)
    if not name then
      break
    end

    local s = body:find("\r?\n?%-%-" .. boundary .. "%-?%-?\r?\n?")
    if not s then
      break
    end

    result[name] = body:sub(1, s)
  end

  return result, nil
end

return M
