local M = {}
local json = vim.json
local uv = vim.uv -- or vim.loop for Neovim < 0.10
local mime = require("tai.mime")

local api_key = os.getenv("GROQ_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing GROQ_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local groq_url = "https://api.groq.com/openai/v1/chat/completions"
local model = "moonshotai/kimi-k2-instruct"
--local model = "compound-beta"
--local model = "llama3-70b-8192"


function M.send_raw(messages, callback)
  local req_body = {
    model = model,
    messages = messages,
  }
  local json_data = json.encode(req_body)

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local result, err_data = {}, {}

  local handle
  handle = uv.spawn("curl", {
    args = {
      "-s", "-X", "POST",
      groq_url,
      "-H", "Authorization: Bearer " .. api_key,
      "-H", "Content-Type: application/json",
      "-d", json_data,
    },
    stdio = { nil, stdout, stderr },
  }, function(code, _)
    stdout:close()
    stderr:close()
    handle:close()

    vim.schedule(function()
      if code ~= 0 then
        vim.notify("[tai] curl exited with code " .. code, vim.log.levels.ERROR)
        callback(nil)
        return
      end

      if #err_data > 0 then
        vim.notify("[tai] API error: " .. table.concat(err_data), vim.log.levels.ERROR)
        callback(nil)
        return
      end

      local ok, parsed = pcall(json.decode, table.concat(result))
      if not ok or not parsed.choices or #parsed.choices == 0 then
        vim.notify("[tai] No valid response from Groq", vim.log.levels.ERROR)
        callback(nil)
        return
      end

      callback(parsed.choices[1].message.content)
    end)
  end)

  uv.read_start(stdout, function(_, chunk)
    if chunk then table.insert(result, chunk) end
  end)

  uv.read_start(stderr, function(_, chunk)
    if chunk then table.insert(err_data, chunk) end
  end)
end


function M.send_chat(messages)
	local resp
	M.send_raw(messages, function()
		local err
		resp, err = mime.parse(resp)
		if err then
			vim.notify("[tai] Failed to decode MIME message: " .. resp, vim.log.levels.ERROR)
			return nil
		end
	end)

	return resp
end

return M
