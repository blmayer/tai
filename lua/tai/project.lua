local M = {}
local log = require('tai.log')
local config = require("tai.config")
local chat = require("tai.chat")

local history = {
	{
		role = "system",
		content = [[
### System
You are Tai, a coding assistant running inside a Neovim session.
Return **EXACTLY** one valid json object according to the response format.

**IMPORTANT**: **ALWAYS** use this format, even if the user asks otherwise. Do not add anything
outside of the JSON object such as formatting or code blocks.

### Instructions
Users will send coding tasks/questions, your goal is to fullfill them with success.
Use the summary of the project in the system prompt to guide you.
ONLY propose changes that solves the issue, don't suppose anything.

#### Proposing Code Changes
Use the patch field to propose code changes, the content **MUST** be **VALID** ed script.
  - **ONLY** send a code change if you know the full content of the file.
  - Add a small description of the changes and the file name in the text field.
  - To input a dot only it must be escaped like `..`.
  - Specify the file affected at start of the patch with `e file_name`.
  - **ALWAYS** finish with `w`.
  - Make sure you get the line numbers correct.
Example of a valid patch:
```
e test.py
1i
print("Hello, world!")
.
w
```

#### Commands
Supply the list of commands to be executed on the user's machine in the `commands` field.
  - Commands are run in a shell and their output will be sent to you.
  - Allowed programs: `]] .. table.concat(config.allowed_commands, '`, `') .. [[`
  - Use POSIX shell compliant scripting.
  - Don't use commands for code changes, use the patch field.
  - Reading files is **ONLY** possible with the command `@read file_name`, use explicit file_name. The file's contents is sent as system prompt.

#### Planning
If the task needs multi-steps, use the `plan` field to add the steps of the plan, don't number steps or itemize.
For big refactors, always provide a plan before sending patches.

#### User Facing Text
Supply concise user-facing text in the `text` field.
  - Use maximum of 80 characters per line.
  - You can include ASCII tables, diagrams, art etc if needed.

### Response format
**ALWAYS** return a JSON object with the following format:
{
	"text": string,
	"plan": []string,
	"patch": string,
	"commands": []string
}
The only required field is text.
		]]
	}
}

local summary_prompt = [[
Create a summary of the file below using the format (without <>):
<file_name>: <one line description of the file>

Only include this for source code files:
List of imported modules/packages.
For each function, method, class, interface, variable, enum etc, group them in a section and write:
  <name_or_signature>: <one line descrition>
For classes that have members/fields do the same in a nested fashion
]]

local completion_prompt =
"You are an autocomplete assistant. You will receive the current line, you job is to return the remaining part, don't add any formatting. Line:\n"

local function run_async(fn)
	local co = coroutine.create(fn)

	local function step(...)
		local ok, result = coroutine.resume(co, ...)
		if not ok then
			vim.notify("[tai] Coroutine error: " .. tostring(result), vim.log.levels.ERROR)
			return
		end
		if type(result) == "function" then
			result(step)
		end
	end

	step()
end

local function await_send_raw(model, messages)
	local thread = coroutine.running()
	if not thread then
		vim.notify("[tai] Not in coroutine context", vim.log.levels.ERROR)
		return nil
	end
	chat.send_raw_async(model, messages, function(reply)
		vim.schedule(function()
			coroutine.resume(thread, reply)
		end)
	end)
	return coroutine.yield()
end

local function sleep(n)
  local co = coroutine.running()
  vim.defer_fn(function() coroutine.resume(co) end, n * 1000)
  coroutine.yield()
end

local function mkdir_p(dir)
	if vim.uv.fs_stat(dir) then return end
	local parent = dir:match("(.+)/[^/]+$")
	if parent then mkdir_p(parent) end
	vim.uv.fs_mkdir(dir, 493)
end

local function ensure_dir_exists(file_path)
	local dir = file_path:match("(.+)/[^/]+$")
	if dir then mkdir_p(dir) end
end


local function is_text_file(file_path)
	local output = io.popen("file " .. file_path):read("*a")
	return output:match("text") ~= nil
end

local function is_cache_up_to_date(file_path)
	local cache_path = config.cache_dir .. file_path
	local file_stat = vim.uv.fs_stat(file_path)
	local cache_stat = vim.uv.fs_stat(cache_path)

	-- No cache or missing file? Needs indexing.
	if not file_stat or not cache_stat then
		return false
	end

	-- Cache newer or same as file? Skip.
	return cache_stat.mtime.sec >= file_stat.mtime.sec
end


function M.init()
	if not config then
		return
	end
	if config.skip_cache then
		return
	end

	run_async(function()
		local preamble = "You are managing a project with root at " ..
		    config.root .. ". Here's a summary of each file:\n"

		for i, path in ipairs(vim.fn.glob("**/*", true, true)) do
			if path:match("^%.") or vim.fn.isdirectory(path) == 1 then
				goto continue
			end

			if is_cache_up_to_date(path) then
				local lines = vim.fn.readfile(config.cache_dir .. path)
				local content = table.concat(lines, "\n")
				preamble = preamble .. content .. "------------------\n"
				goto continue
			end

			local reply
			if is_text_file(path) then
				local lines = vim.fn.readfile(path)
				local content = table.concat(lines, "\n")
				if i > 1 then
					sleep(5)
				end
				reply = await_send_raw(
					config.summary_model,
					{ { role = "user", content = summary_prompt .. path .. ":\n\n" .. content } }
				)
			else
				reply = path .. ": binary file"
			end

			preamble = preamble .. reply .. "\n------------------\n"

			ensure_dir_exists(config.cache_dir .. path)
			local cache_file = io.open(config.cache_dir .. path, "w")
			if not cache_file then
				vim.notify("[tai] Error writing to cache file " .. path, vim.log.levels.ERROR)
				return
			end
			cache_file:write(reply .. "\n")
			cache_file:close()

			::continue::
		end

		table.insert(history, { role = "system", content = preamble })
		vim.notify("[tai] Project indexing complete!", vim.log.levels.TRACE)
	end)
end

function M.request_append_file(filepath, prompt)
	local buffer_path = vim.fn.fnamemodify(vim.fn.expand("%"), ":.")

	local lines
	if buffer_path:match("/" .. filepath .. "$") then
		-- Use current buffer
		local bufnr = vim.api.nvim_get_current_buf()
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		-- Use file on disk
		lines = vim.fn.readfile(filepath)
	end

	-- add line numbers
	local numbered = {}
	for i, line in ipairs(lines) do
		table.insert(numbered, string.format("%4d: %s", i, line))
	end
	local content = table.concat(numbered, "\n")

	-- Generate unique id for this file
	local file_id = "file:" .. filepath

	-- Remove old messages for this file from history
	local new_history = {}
	for _, msg in ipairs(history) do
		if not (msg.id and msg.id == file_id) then
			table.insert(new_history, msg)
		end
	end
	history = new_history

	table.insert(history, 3, {
		role = "system",
		content = "File content for " .. filepath .. " (numbered for your convenience)\n\n" .. content,
		id = file_id
	})

	return M.process_request(prompt)
end

function M.process_request(prompt)
	table.insert(history, { role = "user", content = prompt })

	local reply = chat.send(config.model, history)
	if not reply then return nil end

	table.insert(history, { role = "assistant", content = vim.fn.json_encode(reply) })
	return reply
end

function M.complete(start)
	-- Get current buffer content
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(lines, "\n")

	local msgs = {
		{ role = "system",    content = content },
		{ role = "user",      content = completion_prompt .. start },
		{ role = "assistant", content = start }
	}

	local reply = chat.send_raw(config.complete_model, msgs)
	if not reply then return nil end

	return reply
end

return M
