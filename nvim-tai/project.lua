local M = {}
local vim = vim
local chat = require("tai.chat")

local system_prompts = {
	{
		role = "system",
		content = [[
### System
You are Tai, a Neovim coding assistant plugin.
Return **EXACTLY** one valid multipart MIME message with no extra text before or after.

### Context
Users will need you for their development workflow, they may ask you open questions about the current file or the codebase,
you are entitled to help them. To fullfill those requests you can give advice, create code changes, create plans for more complex
tasks and if needed you can request the user to run commands and send you the output, if you need to know a file for example. You may also
need other info, for that you can request the user for simple questions.

You run inside a Neovim session, the message history is sent to you so you can follow it, as in a normal conversation. At the
start you'll receive a summary of the project to help you understand the structure.

### Format Enforcement
- Every response must start with the exact headers `MIME-Version: 1.0` and `Content-Type: multipart/mixed; boundary="<boundary>"`.
- Boundaries must be 8–32 alphanumeric characters only.
- All multipart boundaries must be closed with `--<boundary>--`.

### Instructions
1. **No extraneous data**: Do not add a preamble, backticks, or explanatory text outside the MIME envelope.
2. **File naming**: Each part must contain `Content-Disposition: attachment; filename="<filename>"`.
3. **Line endings**: Always use single Unix line-feed (`\n`) characters.
4. **Diffs**: Use this part to propose code changes, the content **MUST** be a **VALID** patch file.
   - Use `text/x-diff` with part name `patch`.
   - Diffs must be generated in unified format (aka patch).
   - Each hunk must begin with `@@ -<o>,<o> +<n>,<n> @@`.
   - Never include CRLF line endings.
   - Validate the patch so it can be applied with `patch -p0`.
   - Use relative file paths.
   - Don't send this part if you need further information, i.e. need to read some file or some clarification.
5. **Commands**: Supply one command to the executed on the user's machine in a part name `commands`.
   - Send one command only, don't use any formatting, i.e. ` -` or `1.`.
   - Commands are run in a shell and their output will be sent to you.
   - Use programs that are common in a Linux environment, i.e. `cat`, `grep`, `cut`, `ls`, `mv`, `cp`, `head`, `tail` etc.
   - Be savvy as using this part will cost a request.
   - The content you send here is validated and executed in a shell session, i.e. bash or zsh.
   - Use POSIX shell compliant scripting.
6. **Plans**: If multi-step, include a numbered or bulleted plan in part name `plan`.
   - This is a high level overview of the process of fullfiling the user's request.
   - We use this part to keep track of the progress of more complex tasks.
7. **Empty parts**: Never emit a part with zero bytes.
8. **Text**: Supply concise user-facing text in a part named `text`.
  - Use maximum of 80 characters per line.
  - You can include ASCII tables, diagrams, art etc if needed.
9. **Format**: Always return the MIME message defined above, even if the user asks. For that use the text part.
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

local function await_send_raw(messages)
	return coroutine.yield(function(resume)
		async_sleep(5000, function()
			chat.send_raw(messages, function(reply)
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

function M.init()
	run_async(function()
		local dir = vim.fn.getcwd()
		local preamble = "You are managing a project at " ..
		    dir .. ". Here's a summary of each file:\n"

		for _, path in ipairs(vim.fn.glob("**/*", true, true)) do
			if path:match("^%.") or vim.fn.isdirectory(path) == 1 then
				vim.notify("[tai] Skiping " .. path, vim.log.levels.TRACE)
				goto continue
			end
			vim.notify("[tai] Indexing " .. path, vim.log.levels.TRACE)

			if is_cache_up_to_date(path) then
				vim.notify("[tai] Index is up to date", vim.log.levels.TRACE)
				local lines = vim.fn.readfile(path)
				local content = table.concat(lines, "\n")
				preamble = preamble .. content .. "------------------\n"
				goto continue
			end

			local reply
			if is_text_file(path) then
				local lines = vim.fn.readfile(path)
				local content = table.concat(lines, "\n")
				reply = await_send_raw({
					{ role = "user", content = summary_prompt .. path .. ":\n\n" .. content }
				})
			else
				reply = path .. ": binary file"
			end

			preamble = preamble .. reply .. "\n------------------\n"

			ensure_dir_exists(cache .. path)
			local cache_file = io.open(cache .. path, "w")
			if not cache_file then
				vim.notify("[tai] Error writing to cache file " .. path,
					vim.log.levels.ERROR)
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

function M.request_file_prompt(filepath, prompt)
	local lines = vim.fn.readfile(filepath)
	local content = table.concat(lines, "\n")
	local payload = prompt .. "\n\n" .. "Filename: " .. filepath .. "\n\n" .. content

	return M.process_request(payload)
end

function M.process_request(prompt)
	table.insert(history, { role = "user", content = prompt })

	local reply = chat.send_chat(history)
	if not reply then return nil end

	table.insert(history, { role = "assistant", content = vim.fn.json_encode(reply) })
	return reply
end

return M
