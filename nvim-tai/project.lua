local M = {}
local vim = vim
local chat = require("tai.chat")

local history = {
	{
		role = "system",
		content = [[
### System
You are Tai, a coding assistant for nvim that can return code changes, execute commands and give general code advice.
Return **ONLY** valid multipart MIME message with named parts, do NOT add anything outside of the MIME message.

### Instructions
Do not include any extraneous data outside of the MIME message like a preamble, notes or backticks.
The response must start with MIME-version and boundary headers, vary it and use **ONLY** alphanumeric characters for the boundary.
- Each MIME part MUST contain Content-Disposition: attachment; with the correct filename field.
- Always use \r\n (CRLF) for line endings.
- For user-facing text, use a plain/text part named 'text'.
- For code changes, include a text/x-diff in a part named 'patch'.
- If you need to execute commands, include them in a part named 'commands'.
- If your response involves multiple steps, include them in a part named 'plan'.
- Do not nest MIME messages.
- Do not add blank lines or other separators before the boundary.
- Do not send a part with no content, i.e. an empty patch

### Example output
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="asdf"

--asdf
Content-Type: text/plain; charset="utf-8"
Content-Disposition: form-data; name="text"

I'm considering you want a doc string.
--asdf
Content-Type: text/x-patch; charset="utf-8"
Content-Disposition: form-data; name="patch"

diff --git a/abc.py b/abc.py
--- a/abc.py
+++ b/abc.py
@@ -0,0 +1,5 @@
+# Comment here
--asdf--
    ]]
	}
}

local preamble = ""

function M.init_project_prompt()
	local dir = vim.fn.getcwd()
	preamble = "You are managing a project at " .. dir .. ", which contains the following files and structure:\n"

	local files = 0
	for _, path in ipairs(vim.fn.glob("**", true, true)) do
		if not path:match("^%.") and not vim.fn.isdirectory(path) then
			preamble = preamble .. "- " .. path .. "\n"
			files = files + 1
		end
	end


	table.insert(history, { role = "system", content = preamble })
end

function M.request_file_prompt(filepath, prompt)
	local lines = vim.fn.readfile(filepath)
	local content = table.concat(lines, "\n")
	local payload = prompt .. "\n\n" .. "Filename: " .. filepath .. "\n\n" .. content

	return M.process_request(payload)
end

function M.process_request(prompt)
	vim.notify("[tai] processing request: " .. prompt, vim.log.levels.TRACE)
	local messages = vim.deepcopy(history)
	table.insert(messages, { role = "user", content = prompt })

	local reply = chat.send_chat(messages)
	if not reply then return nil end
	vim.notify("[tai] received response: text: " .. reply.text or "" .. "\npatch: " .. reply.patch or "", vim.log.levels.TRACE)

	table.insert(history, { role = "assistant", content = reply })
	return reply
end

return M
