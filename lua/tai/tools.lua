local M = {}
local log = require('tai.log')
local config = require("tai.config")

-- Import submodules
local tools_io = require("tai.tools.io")
local tools_shell = require("tai.tools.shell")
local tools_edit = require("tai.tools.edit")
local tools_subtask = require("tai.tools.subtask")

-- Re-export functions from submodules
M.read_file = tools_io.read_file
M.limit_output = tools_io.limit_output
M.unsafe_command = tools_shell.unsafe_command
M.exec_command = tools_shell.exec_command
M.edit = tools_edit.edit
M.write = tools_subtask.write
M.image_data_url = tools_subtask.image_data_url

-- Re-export helper functions
M.format_todos = tools_subtask.format_todos
M.format_notes = tools_subtask.format_notes
M.render_memory = tools_subtask.render_memory
M.format_complete = tools_subtask.format_complete
M.run_todos = tools_subtask.run_todos
M.run_notes = tools_subtask.run_notes

-- Tool definitions (API schema)
M.defs = {
	read = {
		type = "function",
		["function"] = {
			name = "read",
			description =
			"Use this to read a file's content, it will return the file's content or range if given. Line numbers are added.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the file to read. Relative to the project's folder."
					},
					range = {
						type = "string",
						description =
						"Optional range of lines to read, starts at 1, colon separated. Formats: \\d: single line; \\d:\\d: inclusive range; $: last line; Negative numbers are counted from the end: -\\d:$: get last lines. Examples: lines 1 throught 10: 1:10; fith line: 5; tenth to last: 10:$; last 5 lines: -5:$.",
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	shell = {
		type = "function",
		["function"] = {
			name = "shell",
		description =
			"Use this tool when you need to run commands in a shell in the project's folder, use it for running builds, exploring the codebase etc. Use relative paths (don't start with /). Do NOT prefix with `cd` to the project root — the shell already starts there. Arguments, pipes (|), conditionals (||, &&), and chaining (;) are allowed. Redirects (>, >>, <, <<, 2>&1 etc.) are NOT allowed. Returns the stdout and stderr of the command. The shell runs in the project's root directory.",
			parameters = {
				type = "object",
				properties = {
					command = {
						type = "string",
						description =
						"The pipeline to be interpreted by the shell in the project's folder. Already cwd is the project root — do not `cd` there first. All paths are relative to the project's folder. Avoid redirections like >, >>, <, <<, 2>&1 etc. 2>&1 is added to the end of the command."
					}
				},
				additionalProperties = false,
				required = { "command" }
			}
		}
	},
	subtask = {
		type = "function",
		["function"] = {
			name = "subtask",
			description =
			"Spawn a focused subtask with its own history so the main chat stays clean. "
				.. "When it finishes (final text reply), only that summary plus its notes/todos "
				.. "return as the tool result. Provide goal, tools, and optionally system_prompt, "
				.. "notes, and todos to seed the child.",
			parameters = {
				type = "object",
				properties = {
					goal = {
						type = "string",
						description =
						"What the subtask must accomplish. Include all context it needs "
							.. "(paths, lines, constraints). It cannot see prior conversation.",
					},
					tools = {
						type = "array",
						items = { type = "string" },
						description =
						"Tools for the child. Read-only: [\"read\",\"shell\",\"send_image\",\"todos\",\"notes\"]. "
							.. "Read-write: add \"edit\",\"write\". Minimal set preferred.",
					},
					system_prompt = {
						type = "string",
						description =
						"Optional system prompt override (persona/constraints). "
							.. "Defaults to the focused subtask agent prompt.",
					},
					notes = {
						type = "string",
						description = "Optional initial notes for the child (e.g. plan snapshot).",
					},
					todos = {
						type = "array",
						description = "Optional initial todos (strings or {text, status}).",
						items = {
							type = "object",
							properties = {
								text = { type = "string" },
								status = {
									type = "string",
									enum = { "pending", "in_progress", "done", "cancelled" },
								},
							},
						},
					},
				},
				additionalProperties = false,
				required = { "goal", "tools" },
			},
		},
	},
	send_image = {
		type = "function",
		["function"] = {
			name = "send_image",
			description =
			"Use this tool to send images to the agent so it can see and interpret screenshots, diagrams, UI mockups, error messages, or any visual content. Make sure you select the correct image file.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description =
						"The path to the image file to send. Relative to the project's folder."
					},
					prompt = {
						type = "string",
						description = "Optional prompt to guide what to look for in the image."
					}
				},
				additionalProperties = false,
				required = { "file" }
			}
		}
	},
	write = {
		type = "function",
		["function"] = {
			name = "write",
			description =
			"Use this to create new files with the given content. Ensures parent directories exist.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to create, relative to project folder"
					},
					content = {
						type = "string",
						description = "Content to write to the file"
					}
				},
				additionalProperties = false,
				required = { "file", "content" }
			}
		}
	},
	edit = {
		type = "function",
		["function"] = {
			name = "edit",
			description =
			"Use this to edit existing files by providing the old content changed. If old_text is empty, changes are made at the start of the file. Matching uses line-by-line comparison after normalizing whitespace (collapse runs of spaces, trim). If the first line of old_text appears multiple times, the matcher tries all possible alignments until the full old_text block matches.",
			parameters = {
				type = "object",
				properties = {
					file = {
						type = "string",
						description = "Path to edit, relative to project folder"
					},
					old_text = {
						type = "string",
						description =
						"Content to be changed. Empty means start of file. This must match exactly (after per-line whitespace normalization). Use the MINIMUM number of context lines needed to uniquely identify the location — typically 1-3 distinctive lines, not large blocks. Don't add line numbers that appear on the read output, they are just for reference."
					},
					new_text = {
						type = "string",
						description = "New content to replace old_text in the file."
					},
					multi = {
						type = "boolean",
						description = "If true, replace every matching occurrence of the old_text block (instead of only the first match). Use when the same change should be applied in multiple places."
					}
				},
				additionalProperties = false,
				required = { "file", "old_text", "new_text" }
			}
		}
	},
	todos = {
		type = "function",
		["function"] = {
			name = "todos",
			description =
			"Update this agent's todo list (injected every turn). Actions: add, update.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "add or update",
						enum = { "add", "update" },
					},
					text = {
						type = "string",
						description = "Todo text. Required for add; optional for update.",
					},
					id = {
						type = "number",
						description = "Todo id. Required for update.",
					},
					status = {
						type = "string",
						description = "pending | in_progress | done | cancelled",
						enum = { "pending", "in_progress", "done", "cancelled" },
					},
				},
				additionalProperties = false,
				required = { "action" },
			},
		},
	},
	notes = {
		type = "function",
		["function"] = {
			name = "notes",
			description =
			"Update this agent's notes (injected every turn). Actions: write (replace), append.",
			parameters = {
				type = "object",
				properties = {
					action = {
						type = "string",
						description = "write or append",
						enum = { "write", "append" },
					},
					content = {
						type = "string",
						description = "Content to write or append.",
					},
				},
				additionalProperties = false,
				required = { "action", "content" },
			},
		},
	},
}

-- Export MAX constants
M.MAX_TOOL_OUTPUT = tools_io.MAX_TOOL_OUTPUT
M.MAX_NOTES_CHARS = tools_io.MAX_NOTES_CHARS

return M
