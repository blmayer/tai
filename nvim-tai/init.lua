local M = {}

local ui = require("tai.ui")
local project = require("tai.project")
local chat = require("tai.chat")

function M.setup(opts)
  require("tai.project").init_project_prompt()
end

function M.prompt_input()
  ui.input("Tai Input: ", function(input)
    if input and input ~= "" then
      local result = chat.send_chat(input)
      ui.show_output_in_vsplit(result)
    end
  end)
end

function M.prompt_full_file()
  local path = vim.fn.expand("%:p")

  ui.input("Tai Input: ", function(user_input)
    if not user_input or user_input == "" then return end
    local result = project.request_file_prompt(path, user_input)
    ui.show_response(result)
  end)
end

function M.operator_send(type)
  local old_reg = vim.fn.getreg('"')
  vim.cmd('normal! gv"zy')
  local text = vim.fn.getreg("z")
  vim.fn.setreg('"', old_reg)

  local result = chat.send_chat(text)
  ui.show_output_in_vsplit(result)
end

function M.operator_send_with_prompt(type)
  local old_reg = vim.fn.getreg('"')
  vim.cmd('normal! gv"zy')
  local text = vim.fn.getreg("z")
  vim.fn.setreg('"', old_reg)

  ui.input("Tai Input: ", function(prompt)
    local full = prompt .. "\n\n" .. text
    local result = chat.send_chat(full)
    ui.show_output_in_vsplit(result)
  end)
end

function M.insert_response()
  ui.input("Tai Insert: ", function(input)
    local result = chat.send_chat(input)
    ui.insert_response(result)
  end)
end

function M.replace_visual()
  ui.input("Tai Replace: ", function(input)
    local result = chat.send_chat(input)
    ui.replace_visual_selection(result)
  end)
end

return M
