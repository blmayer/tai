local M = {}
local json = vim.json
local uv = vim.loop

local api_key = os.getenv("GROQ_API_KEY")
if not api_key then
  vim.schedule(function()
    vim.notify("[tai] ❌ Missing GROQ_API_KEY environment variable.", vim.log.levels.ERROR)
  end)
end

local groq_url = "https://api.groq.com/openai/v1/chat/completions"
local model = "llama3-70b-8192"

function M.send_chat(messages)
  local req_body = {
    model = model,
    messages = messages,
  }

  local json_data = json.encode(req_body)

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local result = {}
  local err_data = {}

  local handle
  handle = uv.spawn("curl", {
    args = {
      "-s", "-X", "POST",
      groq_url,
      "-H", "Authorization: Bearer " .. api_key,
      "-H", "Content-Type: application/json",
      "-d", json_data
    },
    stdio = {nil, stdout, stderr},
  }, function(code, _)
    stdout:close()
    stderr:close()
    handle:close()
    if code ~= 0 then
      vim.schedule(function()
        vim.notify("[tai] curl exited with code " .. code, vim.log.levels.ERROR)
      end)
    end
  end)

  uv.read_start(stdout, function(_, chunk)
    if chunk then
      table.insert(result, chunk)
    end
  end)

  uv.read_start(stderr, function(_, chunk)
    if chunk then
      table.insert(err_data, chunk)
    end
  end)

  vim.wait(10000, function()
    return not uv.is_active(handle)
  end, 10)

  local response = table.concat(result)
  if #err_data > 0 then
    vim.schedule(function()
      vim.notify("[tai] API error: " .. table.concat(err_data), vim.log.levels.ERROR)
    end)
    return nil
  end

  local ok, parsed = pcall(json.decode, response)
  if not ok then
    vim.notify("[tai] Failed to decode JSON: " .. response, vim.log.levels.ERROR)
    return nil
  end

  if not parsed.choices or #parsed.choices == 0 then
    vim.notify("[tai] No response from Groq", vim.log.levels.ERROR)
    return nil
  end

  return parsed.choices[1].message.content
end

return M

