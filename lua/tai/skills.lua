--- tai/skills.lua — Skill discovery, loading, and system prompt injection.
---
--- Follows the Agent Skills specification (https://agentskills.io/specification):
---
--- Required:
---   - Skill = directory containing SKILL.md
---   - SKILL.md = YAML frontmatter + Markdown body
---   - Frontmatter fields:
---       name:        1–64 chars; [a-z0-9-]+; no leading/trailing/consecutive hyphens;
---                    must match parent directory name
---       description: 1–1024 chars; non-empty; what it does and when to use it
---
--- Progressive disclosure:
---   1. Catalog (name + description) injected at startup for all valid skills
---   2. Full SKILL.md body injected when a skill is loaded via the skill tool
---   3. scripts/ / references/ / assets/ are left on disk for on-demand reads
---
--- Optional frontmatter (parsed but not required): license, compatibility,
--- metadata, allowed-tools
---
--- Skill directories (project overrides user on same id):
---   1. ~/.config/tai/skills/
---   2. <project>/.tai-skills/

local M = {}
local log = require("tai.log")
local config = require("tai.config")

--- Skill entry:
--- {
---   id       = "my-skill",       -- directory name (== frontmatter name)
---   name     = "my-skill",       -- validated frontmatter name
---   desc     = "…",              -- validated frontmatter description
---   path     = "/abs/path/to/dir",
---   file     = "/abs/path/to/SKILL.md",
---   content  = nil | string,     -- markdown body only (nil until loaded)
---   loaded   = false,
---   source   = "project" | "user",
--- }

--- @type table<string, table>
M.registry = {}

--- @type string[]
M.order = {}

-- Directories --

local function user_skills_dir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if not xdg or xdg == "" then
		xdg = (os.getenv("HOME") or "~") .. "/.config"
	end
	return xdg .. "/tai/skills"
end

local function project_skills_dir()
	if config.root then
		return config.root .. "/.tai-skills"
	end
	return nil
end

-- Validation (Agent Skills required constraints) --

--- Validate frontmatter `name` per agentskills.io/specification.
--- @param name string
--- @param dir_name string  parent directory name (must match)
--- @return string|nil  error message, or nil if valid
local function validate_name(name, dir_name)
	if not name or name == "" then
		return "missing required frontmatter field 'name'"
	end
	if #name > 64 then
		return string.format("name exceeds 64 characters (%d)", #name)
	end
	-- Only lowercase a-z, digits, and hyphens (Lua: `%-` is literal hyphen).
	if name:find("[^a-z0-9%-]") then
		return "name must be lowercase letters, numbers, and hyphens only: '" .. name .. "'"
	end
	if name:sub(1, 1) == "-" or name:sub(-1) == "-" then
		return "name must not start or end with a hyphen: '" .. name .. "'"
	end
	if name:find("%-%-", 1, false) then
		return "name must not contain consecutive hyphens: '" .. name .. "'"
	end
	if name ~= dir_name then
		return string.format(
			"name '%s' must match parent directory name '%s'",
			name,
			dir_name
		)
	end
	return nil
end

--- Validate frontmatter `description` per agentskills.io/specification.
--- @param desc string
--- @return string|nil  error message, or nil if valid
local function validate_description(desc)
	if not desc or desc == "" then
		return "missing required frontmatter field 'description'"
	end
	if #desc > 1024 then
		return string.format("description exceeds 1024 characters (%d)", #desc)
	end
	return nil
end

-- YAML frontmatter parsing --

--- Unquote a simple YAML scalar (single/double quotes).
--- @param s string
--- @return string
local function unquote(s)
	s = s:match("^%s*(.-)%s*$") or s
	if #s >= 2 then
		local q = s:sub(1, 1)
		if (q == '"' or q == "'") and s:sub(-1) == q then
			return s:sub(2, -2)
		end
	end
	return s
end

--- Parse YAML frontmatter block into a flat string→string map.
--- Handles simple `key: value`, multi-line `key: >` / `key: |` blocks, and
--- one-level nested maps (nested keys stored as "parent.child").
--- @param yaml string
--- @return table<string, string>
local function parse_frontmatter_yaml(yaml)
	local fields = {}
	local lines = {}
	for line in (yaml .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end

	local i = 1
	while i <= #lines do
		local line = lines[i]
		if line:match("^%s*$") or line:match("^%s*#") then
			i = i + 1
		else
			local key, rest = line:match("^([%w][%w%-_]*)%s*:%s*(.*)$")
			if not key then
				i = i + 1
			else
				rest = (rest or ""):match("^%s*(.-)%s*$") or ""
				local block_style = rest:match("^([>|])[-+]?$")
				if block_style then
					local parts = {}
					i = i + 1
					while i <= #lines do
						local cont = lines[i]
						if cont:match("^%s*$") then
							table.insert(parts, "")
							i = i + 1
						elseif cont:match("^%s") then
							table.insert(parts, cont:match("^%s*(.-)%s*$") or cont)
							i = i + 1
						else
							break
						end
					end
					local joined = table.concat(parts, block_style == "|" and "\n" or " ")
					fields[key] = joined:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
				elseif rest == "" then
					fields[key] = fields[key] or ""
					i = i + 1
					while i <= #lines do
						local cont = lines[i]
						if cont:match("^%s*$") then
							i = i + 1
						elseif cont:match("^%s+") then
							local nk, nv = cont:match("^%s+([%w][%w%-_]*)%s*:%s*(.*)$")
							if nk then
								fields[key .. "." .. nk] = unquote(nv or "")
							end
							i = i + 1
						else
							break
						end
					end
				else
					fields[key] = unquote(rest)
					i = i + 1
				end
			end
		end
	end
	return fields
end

--- Parse and validate a SKILL.md file (Agent Skills required format).
--- @param filepath string
--- @param dir_name string  parent directory name
--- @return table|nil  {name, desc, body} on success
--- @return string|nil  error message on failure
local function parse_skill_file(filepath, dir_name)
	local f = io.open(filepath, "r")
	if not f then
		return nil, "could not open file"
	end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then
		return nil, "empty file"
	end

	raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")

	-- Required: YAML frontmatter delimited by ---
	local fm_body, md_body = raw:match("^%-%-%-\n(.-)\n%-%-%-\n?(.*)$")
	if not fm_body then
		return nil, "missing YAML frontmatter (expected ---\\n...\\n---)"
	end

	local fields = parse_frontmatter_yaml(fm_body)
	local name = fields.name or ""
	local desc = fields.description or ""

	local err = validate_name(name, dir_name)
	if err then
		return nil, err
	end
	err = validate_description(desc)
	if err then
		return nil, err
	end

	local body = md_body or ""
	body = body:gsub("^%s*\n", "")

	return {
		name = name,
		desc = desc,
		body = body,
	}, nil
end

-- Scanning --

--- Scan a single directory for skill sub-directories containing valid SKILL.md.
--- Invalid skills (failed required validation) are skipped and logged.
--- @param dir string
--- @param source string  "project" or "user"
local function scan_dir(dir, source)
	if vim.fn.isdirectory(dir) ~= 1 then
		return
	end
	local entries = vim.fn.readdir(dir)
	for _, entry in ipairs(entries) do
		local skill_dir = dir .. "/" .. entry
		local skill_file = skill_dir .. "/SKILL.md"
		if vim.fn.isdirectory(skill_dir) == 1 and vim.fn.filereadable(skill_file) == 1 then
			local id = entry
			-- Project skills override user skills with the same id
			if not M.registry[id] or source == "project" then
				local parsed, err = parse_skill_file(skill_file, id)
				if not parsed then
					log.debug(string.format(
						"[skills] skip invalid skill %s (%s): %s",
						id,
						source,
						err or "unknown error"
					))
				else
					local existed = M.registry[id] ~= nil
					M.registry[id] = {
						id = id,
						name = parsed.name,
						desc = parsed.desc,
						path = skill_dir,
						file = skill_file,
						content = nil,
						loaded = false,
						source = source,
					}
					if not existed then
						table.insert(M.order, id)
					end
					log.debug(string.format("[skills] found: %s (%s)", id, source))
				end
			end
		end
	end
end

--- (Re-)scan skill directories and populate the registry.
--- Preserves loaded state for skills that still exist and remain valid.
function M.scan()
	local prev_loaded = {}
	for id, s in pairs(M.registry) do
		if s.loaded then
			prev_loaded[id] = true
		end
	end
	M.registry = {}
	M.order = {}

	scan_dir(user_skills_dir(), "user")
	local pdir = project_skills_dir()
	if pdir then
		scan_dir(pdir, "project")
	end

	for id in pairs(prev_loaded) do
		if M.registry[id] then
			M.load(id)
		end
	end
end

-- Load / Unload --

--- Load a skill: read its SKILL.md body and mark it active.
--- @param id string  skill name / directory name
--- @return string  result message
function M.load(id)
	local skill = M.registry[id]
	if not skill then
		return "Error: skill '" .. id .. "' not found. Use action 'list' to see available skills."
	end
	if skill.loaded then
		return "Skill '" .. id .. "' is already loaded."
	end
	local parsed, err = parse_skill_file(skill.file, skill.id)
	if not parsed then
		return "Error: skill '" .. id .. "' is invalid: " .. (err or "parse failed")
	end
	-- Progressive disclosure step 2: inject markdown body only
	skill.content = parsed.body
	skill.name = parsed.name
	skill.desc = parsed.desc
	skill.loaded = true
	log.info("[skills] loaded: " .. id)
	return "Skill '" .. id .. "' loaded."
end

--- Unload a skill: clear its content and mark it inactive.
--- @param id string
--- @return string
function M.unload(id)
	local skill = M.registry[id]
	if not skill then
		return "Error: skill '" .. id .. "' not found."
	end
	if not skill.loaded then
		return "Skill '" .. id .. "' is not loaded."
	end
	skill.content = nil
	skill.loaded = false
	log.info("[skills] unloaded: " .. id)
	return "Skill '" .. id .. "' unloaded."
end

-- Rendering --

--- Compact catalog for the system prompt (progressive disclosure step 1).
--- Only name + description — never the full body.
function M.render_catalog()
	if #M.order == 0 then
		return ""
	end
	local lines = {
		"## Available Skills",
		"",
		"Skills follow the Agent Skills format (name + description below). "
			.. "Use the `skill` tool with action `load` and the skill name when relevant; "
			.. "that injects the full skill instructions into context.",
		"",
	}
	for _, id in ipairs(M.order) do
		local s = M.registry[id]
		local status = s.loaded and " [loaded]" or ""
		table.insert(lines, string.format("- **%s**: %s%s", s.name, s.desc, status))
	end
	return table.concat(lines, "\n")
end

--- Full markdown body of all loaded skills (progressive disclosure step 2).
function M.render_loaded()
	local parts = {}
	for _, id in ipairs(M.order) do
		local s = M.registry[id]
		if s.loaded and s.content then
			table.insert(parts, "### Skill: " .. s.name .. "\n\n" .. s.content)
		end
	end
	if #parts == 0 then
		return ""
	end
	return table.concat(parts, "\n\n---\n\n")
end

--- List skills for the tool response.
function M.list()
	if #M.order == 0 then
		return "No skills found. Place valid Agent Skills under ~/.config/tai/skills/<name>/SKILL.md "
			.. "or <project>/.tai-skills/<name>/SKILL.md "
			.. "(required frontmatter: name, description)."
	end
	local lines = {}
	for _, id in ipairs(M.order) do
		local s = M.registry[id]
		local status = s.loaded and "loaded" or "available"
		table.insert(
			lines,
			string.format("[%s] %s — %s  (%s)", status, s.name, s.desc, s.source)
		)
	end
	return table.concat(lines, "\n")
end

--- Status of a single skill.
--- @param id string
--- @return string
function M.status(id)
	local skill = M.registry[id]
	if not skill then
		return "Error: skill '" .. id .. "' not found."
	end
	return table.concat({
		"Skill: " .. skill.name,
		"Status: " .. (skill.loaded and "loaded" or "available"),
		"Source: " .. skill.source,
		"Path: " .. skill.path,
		"Description: " .. skill.desc,
	}, "\n")
end

-- Expose for tests
M._parse_skill_file = parse_skill_file
M._validate_name = validate_name
M._validate_description = validate_description

M.scan()

return M
