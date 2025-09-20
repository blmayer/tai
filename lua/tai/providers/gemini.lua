local M = {}

local config = require("tai.config")
local log = require("tai.log")
local json = vim.json
local uv = vim.uv

local api_key = os.getenv("GEMINI_API_KEY")
if not api_key then
	vim.schedule(function()
		vim.notify("[tai] ❌ Missing GEMINI_API_KEY environment variable.", vim.log.levels.ERROR)
	end)
end

local url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

M.system_prompt = [[
You are Tai, a coding assistant running inside a Neovim session.

INSTRUCTIONS
Users will send coding tasks/questions, your goal is to fullfill them with success.
ONLY propose steps that solves the issue, don't suppose anything.
Generate code changes is the user wants, use the ed format explainded below.

UNDERSTANDING NEEDED CODE CHANGES
Understand the problem and the path to the solution and generate patches to
implement the solution.

USING PLANS
For solutions that will need many steps that includes interaction from the user generate
a step by step plan and pass it to the writer agent, so it will forward it to the user.
Use the plan created to guide you and the agents towards the goal.

COMPLEX TASKS
Sometimes the task will be too complex to be solved at once, in those cases you can inform the user
of the need, you can also ask the user to run commands on its machine and send you the output.

COMMANDS
Supply the list of commands to be executed on the user's machine for the writer agent.
  - Commands are run in a shell and their output will be sent to you.
  - Allowed programs: `]] .. table.concat(config.allowed_commands, '`, `') .. [[`
  - Use POSIX shell compliant scripting.
  - Don't use commands for code changes, use the patch field.
  - Reading files is **ONLY** possible with the command `@read file_name`, use explicit file_name. The file's contents is sent as system prompt.

ED FORMAT

General Rules
- A script is a sequence of ed commands followed by w and q.
- To input a dot only it must be escaped like `..`.
- Lines are addressed by number or by special symbols.
- Ranges can apply to a single line, multiple lines, or the whole file.
- When you use a, i, or c to add or replace text, you enter input mode. You type content directly.
- To return to command mode, you enter a line containing only a single `.`.

Addressing and Ranges
1 	first line
$ 	last line
. 	current line
0 	line before the first line (only valid with a to prepend)
N,M 	lines N through M (inclusive)
% 	shorthand for 1,$ (the whole file)
/regex/ first line matching regex
?regex? search backwards for regex

Editing Commands
a		append after the addressed line
  		0a appends at the start of the file (prepending), use it for empty files.
i		insert before the addressed line
c		change (replace) the addressed line(s)
d		delete the addressed line(s)
s/pat/repl/	substitute text in the current line (use g at the end for global)
m		move addressed line(s) to after another line (e.g. 1,3m$)
t		copy addressed line(s) after another line (like m, but duplicate)

File Commands
e filename	open file (if it doesn’t exist, buffer is empty)
r filename	read contents of file into current buffer (after current line)
w [filename]	write buffer to file (creates if missing)
q		quit

EXAMPLES
- Addind text at start of file:
e test.py
0a
print("Hello, world!")
.
w
q

- Replace line 5 with new content:
e foo.lua
5c
print("Hello, world")
.
w
q

- Delete all lines containing “DEBUG”:
e foo.lua
g/DEBUG/d
w
q

- Substitute globally in whole file:
e foo.lua
%s/foo/bar/g
w
q

- A content line with escaped `.`:
e foo.lua
15a
new line
next line is only a dot.
..
some text
.
w
q

NOTES
You must know the original content of the files affected.

RESPONSE FORMAT
**ALWAYS** return a JSON object with the following format:
{
       "text": string,
       "plan": []string,
       "patch": string,
       "commands": []string
}
The only required field is text.
]]

local response_format = {
	type = "json_object",
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
					description = "Patch part of answer, a valid ed script text containing the changes requested.",
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

function M.send_raw_async(model, messages, callback)
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
			mistral_url,
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
				vim.notify("[tai] No valid response from Mistral: " .. table.concat(result), vim.log.levels.ERROR)
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

function M.send_raw(model, messages)
	local req_body = {
		model = model,
		messages = vim.tbl_map(
			function(m) return { role = m.role, content = m.content } end,
			messages
		)
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
			mistral_url,
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
		vim.notify("[tai] No response from Mistral, received " .. response, vim.log.levels.ERROR)
		return nil
	end

	return parsed.choices[1].message.content
end

function M.send(model, messages)
	local req_body = {
		model = model,
		messages = vim.tbl_map(
			function(m) return { role = m.role, content = m.content } end,
			messages
		),
		response_format = response_format
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
			url,
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

	log.debug("response: " .. response)
	local ok, parsed = pcall(json.decode, response)
	if not ok then
		vim.notify("[tai] Failed to decode JSON: " .. response, vim.log.levels.ERROR)
		return nil
	end

	if not parsed.choices or #parsed.choices == 0 then
		vim.notify("[tai] No response from Mistral, received " .. response, vim.log.levels.ERROR)
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

