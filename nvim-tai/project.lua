local M = {}
local vim = vim
local chat = require("tai.chat")

local history = {
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
5. **Commands**: Supply an executable list with part name `commands`.
6. **Plans**: If multi-step, include a numbered or bulleted plan in part name `plan`.
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
 This is a test.
 Another line.
 Final line.
--asdf--

### Example output
    ]]
	}
}

local preamble = ""

function M.init_project_prompt()
	local dir = vim.fn.getcwd()
	preamble = "You are managing a project at " .. dir .. ", which contains the following files and structure:\n"

	for _, path in ipairs(vim.fn.glob("**", true, true)) do
		if not path:match("^%.") and not vim.fn.isdirectory(path) then
			preamble = preamble .. "- " .. path .. "\n"
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
	local messages = vim.deepcopy(history)
	table.insert(messages, { role = "user", content = prompt })

	local reply = chat.send_chat(messages)
	if not reply then return nil end
	--vim.api.nvim_echo({{"[tai] received response: text: " .. reply.text or "" .. "\npatch: " .. reply.patch or "", "None"}}, false, {})

	table.insert(history, { role = "assistant", content = vim.fn.json_encode(reply) })
	return reply
end

return M
