local M = {}
local json = vim.json
local chat = require("tai.chat")
local config = require("tai.config")

local system_prompts = {
	{
		role = "system",
		content = [[
### System
You are Tai, a Neovim coding assistant plugin.
Return **EXACTLY** one valid json object according to the passed schema.

### Context
You run inside a Neovim session, the message history is sent to you so you can follow it, as in a normal conversation. At the
start you'll receive a summary of the project to help you understand the structure.

Users will need you for their development workflow, they may ask you open questions about the current file or the codebase,
you are entitled to help them. To fullfill those requests you can give advice, create code changes, create plans for more complex
tasks and if needed you can request the user to run commands and send you the output, if you need to know a file for example. You may also
need other info, for that you can request the user for simple questions.

Respond correctly to the prompts, don't propose code changes if the user didn't ask.

### Format Enforcement
- Every response must comply with the json schema named "tai_response", only send valid JSON.
- In case you forget, the "tai_response" schema is:
```
		]] .. json.encode(chat.response_format) .. [[
```

### Instructions
1. **No extraneous data**: Do not add a preamble, backticks, or explanatory text outside the JSON response.
2. **Line endings**: Always use single Unix line-feed (`\n`) characters.
3. **Diffs**: Use the patch field to propose code changes, the content **MUST** be a **VALID** patch file.
   - Diffs must be generated in unified format (aka patch).
   - Always use LF (`\n`) line endings, never CRLF.
   - Validate the patch so it can be applied with `patch -p0`.
   - Use relative file paths.
   - Don't send this part if you need further information, i.e. need to read some file or some clarification.
4. **Commands**: Supply the list of commands to the executed on the user's machine in the `commands` field.
   - Commands are run in a shell and their output will be sent to you.
   - Use programs that are common in a Linux environment, i.e. `cat`, `grep`, `cut`, `ls`, `mv`, `cp`, `head`, `tail` etc.
   - Be savvy as using this part will cost a request.
   - The content you send here is validated and executed in a shell session, i.e. bash or zsh.
   - Use POSIX shell compliant scripting.
5. **Plans**: If multi-step, use the `plan` field to add the steps of the plan.
   - This is a high level overview of the process of fullfiling the user's request.
   - We use this part to keep track of the progress of more complex tasks.
6. **Text**: Supply concise user-facing text in the `text` field.
  - Use maximum of 80 characters per line.
  - You can include ASCII tables, diagrams, art etc if needed.
		]]
	}
}

local summary_prompt = [[
Create a summary of the file below using the format (without <>):
<file name>: <one line description of the file>

Only include this for source code files:
For each function, method, class, interface, variable, enum etc, group them in a section and write:
  <name or signature>: <one line descrition>
For classes that have members/fields do the same in a nested fashion
]]

local history = vim.deepcopy(system_prompts)
local cache = ".tai-cache/"
local tai_root = nil

local function run_async(fn)
	local co = coroutine.create(fn)

	local function step(...)
		local ok, wait_fn = coroutine.resume(co, ...)
		if not ok then
			vim.notify("[tai] Coroutine error: " .. tostring(wait_fn), vim.log.levels.ERROR)
			return
		end
		if type(wait_fn) == "function" then
			wait_fn(step)
		end
	end

	step()
end

local function async_sleep(ms, cb)
	local t = vim.uv.new_timer()
	t:start(ms, 0, function()
		t:stop()
		t:close()
		vim.schedule(cb) -- ensures callback runs on main thread
	end)
end

local function await_send_raw(model, messages)
	return coroutine.yield(function(resume)
		async_sleep(5000, function()
			chat.send_raw(model, messages, function(reply)
				resume(reply)
			end)
		end)
	end)
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
	local cache_path = cache .. file_path
	local file_stat = vim.uv.fs_stat(file_path)
	local cache_stat = vim.uv.fs_stat(cache_path)

	-- No cache or missing file? Needs indexing.
	if not file_stat or not cache_stat then
		return false
	end

	-- Cache newer or same as file? Skip.
	return cache_stat.mtime.sec >= file_stat.mtime.sec
end

local function read_tai_config()
	local file = io.open(tai_root .. "/.tai", "r")
	if not file then return {} end
	return vim.fn.json_decode(file:read("*a")) or {}
end

local function find_tai_root()
	local current = vim.fn.getcwd()
	while current ~= "/" do
		local tai_file = current .. "/.tai"
		if vim.fn.filereadable(tai_file) == 1 then
			return current
		end
		current = vim.fn.fnamemodify(current, ":h")
	end
	return nil
end

function M.init()
	tai_root = find_tai_root()
	if not tai_root then
		vim.notify("[tai] .tai file not found, quitting.", vim.log.levels.WARN)
		return
	end
	cache = tai_root .. "/.tai-cache/"
	
	config.load(tai_root .. "/.tai")
	vim.inspect(tai_root, config)
	if config.skip_config then
		return
	end

	run_async(function()
		local preamble = "You are managing a project with root at " ..
		    tai_root .. ". Here's a summary of each file:\n"

		for _, path in ipairs(vim.fn.glob("**/*", true, true)) do
			if path:match("^%.") or vim.fn.isdirectory(path) == 1 then
				goto continue
			end

			if is_cache_up_to_date(path) then
				local lines = vim.fn.readfile(path)
				local content = table.concat(lines, "\n")
				preamble = preamble .. content .. "------------------\n"
				goto continue
			end

			local reply
			if is_text_file(path) then
				local lines = vim.fn.readfile(path)
				local content = table.concat(lines, "\n")
				reply = await_send_raw(
					config.summary_model,
					{{ role = "user", content = summary_prompt .. path .. ":\n\n" .. content }}
				)
			else
				reply = path .. ": binary file"
			end

			preamble = preamble .. reply .. "\n------------------\n"

			ensure_dir_exists(cache .. path)
			local cache_file = io.open(cache .. path, "w")
			if not cache_file then
				vim.notify("[tai] Error writing to cache file " .. path, vim.log.levels.ERROR)
				return
			end
			cache_file:write(reply .. "\n")
			cache_file:close()

			::continue::
		end

		table.insert(system_prompts, { role = "system", content = preamble })
		vim.notify("[tai] Project indexing complete!", vim.log.levels.TRACE)
	end)
end

function M.request_append_file(filepath, prompt)
	-- Read file content
	local lines = vim.fn.readfile(filepath)
	local content = table.concat(lines, "\n")

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

	-- Add new message with file content
	table.insert(history, {
		role = "system",
		content = "File content for " .. filepath .. "\n\n" .. content,
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

return M
