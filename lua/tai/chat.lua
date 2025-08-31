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

M.response_format = {
	type = "json_schema", 
	json_schema = {
		name = "tai_response", 
		description = "The only response format for Tai.",
		schema = {
			type = "object",
			additionalProperties = false,
			required = {"text"},
			properties = {
				text = {
					type = "string",
					description = "Textual part of answer, intended for the user",
				},
				patch = {
					type = "string",
					description = "Patch part of answer, a valid diff text containing the changes requested.",
				},
				commands = {
					type = "array",
					description = "Commands part of answer, a list of commands to be ran in order in the user's machine.",
					items = {
						type = "string"
					}
				},
				plan = {
					type = "array",
					description = "Plan part of answer, a list of steps to be taken in order to fullfil the big change requested.",
					items = {
						type = "string"
					}
				},

			}
		}
	}
}

function M.send_raw(model, messages, callback)
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

function M.send(model, messages)
	local req_body = {
		model = model,
		messages = vim.tbl_map(
			function(m) return { role = m.role, content = m.content } end,
			messages
		),
		response_format = M.response_format
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
		stdio = { nil, stdout, stderr },
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
	vim.wait(60000, function()
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
		vim.notify("[tai] No response from Groq, received " .. response, vim.log.levels.ERROR)
		return nil
	end

	local ok, fields = pcall(json.decode, parsed.choices[1].message.content)
	if not ok then
		vim.notify("[tai] Failed to decode message: " .. response, vim.log.levels.ERROR)
		return nil
	end

	return fields
end

return M
