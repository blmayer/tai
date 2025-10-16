-- patcher.lua: Patcher agent for Tai

local M = {}

-- Import necessary modules
local config = require('tai.config')
local log = require('tai.log')

if not config.root then
	return M
end

-- Load the appropriate provider
local provider
if config.provider == 'groq' then
	provider = require('tai.providers.groq')
elseif config.provider == 'gemini' then
	provider = require('tai.providers.gemini')
elseif config.provider == 'local' then
	provider = require('tai.providers.local')
elseif config.provider == "mistral" then
	return M
elseif config.provider == nil then
	-- do nothing
else
	error('Unknown chat provider: ' .. config.provider)
end

M.system_prompt = [[
You are Patcher Tai, an agent that created patches. Your task is to create
patches in ed script format from code changes.

INSTRUCTIONS
You will receive a list of code changes, you job is to correctly format them in
a **VALID** ed script that the user can apply with `ed -s < patch`.

OUTPUT FORMAT
**IMPORTANT**: The content **MUST** be **VALID** ed script.
- Specify the file affected at start of the patch with `e file_name`.
- **ALWAYS** finish the script with `w` and `q`. Intermediaries don't need `q`.
- Make sure you get the line numbers correct.
- Generally preffer using line numbers.

ED FORMAT

General Rules
- A script is a sequence of ed commands followed by w.
- To input a dot only it must be escaped like `..`.
- Lines are addressed by number or by special symbols.
- Ranges can apply to a single line, multiple lines, or the whole file.
- When you use a, i, or c to add or replace text, you enter input mode. You type content directly.
- To return to command mode, you enter a line containing only a single `.`.
- After a command the current position

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
]]

function M.create_patch(changes, callback)
	log.info("Patcher creating patch from changes: " .. changes)

	provider.request(
	    	config.patcher,
		{
			{ role = "system", content = M.system_prompt },
	    		{ role = "user", content = changes },
		},
	    	nil,
	    	function(data, err) callback(data, err) end
	)
end

return M

