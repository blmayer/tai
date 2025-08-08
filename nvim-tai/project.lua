local M = {}
local vim = vim
local chat = require("tai.chat")

local system_prompts = {
	{
		role = "system",
		content = [[
### System
You are Tai, a Neovim coding assistant.
Return **EXACTLY** one valid multipart MIME message with no extra text before or after.

### Format Enforcement
- Every response must start with the exact headers `MIME-Version: 1.0` and `Content-Type: multipart/mixed; boundary="<boundary>"`.
- Boundaries must be 8–32 alphanumeric characters only.
- All multipart boundaries must be closed with `--<boundary>--`.

### Instructions
1. **No extraneous data**: Do not add a preamble, backticks, or explanatory text outside the MIME envelope.
2. **File naming**: Each part must contain `Content-Disposition: attachment; filename="<filename>"`.
3. **Line endings**: Always use single Unix line-feed (`\n`) characters.
4. **Diffs**:
   - Use `text/x-diff` with part name `patch`.
   - Diffs must be generated in unified format (aka patch).
   - Each hunk must begin with `@@ -<o>,<o> +<n>,<n> @@`.
   - Never include CRLF line endings.
   - Validate the patch so it can be applied with `patch -p0`.
   - Use relative file paths.
   - Don't send this part if you need further information, i.e. need to read some file or some clarification.
5. **Commands**: Supply an executable list with part name `commands`.
   - Send one command per line, don't use any formatting, i.e. ` -` or `1.`.
   - Commands are run in a shell and their output will be sent to you.
   - Use programs that are common in a Linux environment, i.e. `cat`, `grep`, `cut`, `ls`, `mv`, `cp`, `head`, `tail` etc.
   - Be savvy as having one or more commands will cost a request.
6. **Plans**: If multi-step, include a numbered or bulleted plan in part name `plan`.
   - This is a high level overview of the process of fullfiling the user's request.
   - We use this part to keep track of the progress of more complex tasks.
7. **Empty parts**: Never emit a part with zero bytes.
8. **Text**: Supply concise user-facing text in a part named `text`.

### Example Response
All examples must match this format verbatim except boundary strings and content.

MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="asdf"

--asdf
Content-Type: text/plain; charset="utf-8"
Content-Disposition: attachment; filename="text"

I'm considering you want a doc string.
--asdf
Content-Type: text/x-patch; charset="utf-8"
Content-Disposition: attachment; filename="patch"

--- file.txt	2025-08-05 14:30:00
+++ file.txt	2025-08-05 14:31:00
@@ -1,4 +1,4 @@
-Hello world
+Hello universe
+This is a test.
+Another line.
+Final line.
--asdf--
    ]]
	}
}

local history = vim.deepcopy(system_prompts)

local allowed_commands = {
	["cat"] = true, ["tail"] = true, ["head"] = true, ["grep"] = true,
	["cut"] = true, ["ls"] = true, ["wc"] = true, ["sort"] = true
}

function M.init_project_prompt()
	local dir = vim.fn.getcwd()
	local preamble = "You are managing a project at " .. dir .. ", which contains the following files and structure:\n"

	for _, path in ipairs(vim.fn.glob("**", true, true)) do
		if not path:match("^%.") and not vim.fn.isdirectory(path) then
			preamble = preamble .. "- " .. path .. "\n"
		end
	end


	table.insert(system_prompts, { role = "system", content = preamble })
end

function M.request_file_prompt(filepath, prompt)
	local lines = vim.fn.readfile(filepath)
	local content = table.concat(lines, "\n")
	local payload = prompt .. "\n\n" .. "Filename: " .. filepath .. "\n\n" .. content

	return M.process_request(payload)
end

local function validate_command(cmd)
	local parts = vim.split(cmd, "%s+")
	if #parts == 0 then return false end

	local base = parts[1]:match("^([^/]+)$")
	if not base or not allowed_commands[base] then
		return false
	end

	for _, arg in ipairs(parts) do
		if arg:sub(1, 1) == "-" then
			goto continue
		end
		if arg:sub(1, 1) == "/" then
			return false
		end
		if arg:match("%.%.") then
			return false
		end
		if arg:match("[*?]") then
			return false
		end
		::continue::
	end

	return true
end

local function run_command(cmd)
	local env = {}
	for _, name in ipairs({ "PATH" }) do
		env[#env + 1] = name .. "=" .. (os.getenv(name) or "")
	end

	local env_prefix = ""
	for _, v in ipairs(env) do
		local name, value = v:match("^([^=]+)=(.*)$")
		if name and value then
			env_prefix = env_prefix .. name .. "='" .. value:gsub("'", "'\\''") .. "' "
		end
	end

	local full_cmd = env_prefix .. cmd .. " 2>&1"
	local handle = io.popen(full_cmd, "r")
 	if not handle then
 		return nil, "Failed to run command"
 	end

	local output = handle:read("*a")
	handle:close()

	return output
end

function M.process_request(prompt)
	local messages = vim.deepcopy(system_prompts)
	table.insert(history, { role = "user", content = prompt })
	table.insert(messages, { role = "user", content = prompt })

	local reply = chat.send_chat(messages)
	if not reply then return nil end

	if reply and reply.commands and #reply.commands > 0 then
		table.insert(messages, {
			role = "assistant",
			content = vim.fn.json_encode({
				text = reply.text,
				plan = reply.plan,
				commands = reply.commands
			})
		})

		local cmds = vim.split(reply.commands, "\n", { trimempty = true })

		local outputs = {}
		for _, cmd in ipairs(cmds) do
			vim.schedule(function()
				vim.notify("[tai] Assistant requested command: " .. cmd, vim.log.levels.TRACE)
			end)

			local output
			if validate_command(cmd) then
				output = run_command(cmd)
			else
				output = "[tai] Command " .. cmd .. " is not allowed"
			end
			table.insert(outputs, ("$ %s\n%s"):format(cmd, output))
		end

		local followup = {
			role = "user",
			content = table.concat(outputs, "\n\n")
		}

		table.insert(messages, followup)

		vim.schedule(function()
			vim.notify("[tai] Sending commands output", vim.log.levels.TRACE)
		end)
		reply = chat.send_chat(messages)
	end

	table.insert(history, { role = "assistant", content = vim.fn.json_encode(reply) })
	return reply
end

return M
