local M = {}


function M.show_response(fields)
  if not fields.text and not fields.patch then
    return
  end
  local lines = vim.split(fields.text .. fields.patch or "", "\n", { trimempty = true })

  vim.schedule(function()
    -- Create a new horizontal split
    vim.cmd("vnew")
    local new_win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_width(new_win, 40)

    -- Set buffer options to make it a scratch window
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].filetype = "tai-output"

    -- Insert content
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_command("au BufDelete <buffer> lua require('tai').apply_patch('"..fields.patch.."')")

    -- Optional: prevent accidental edits
    vim.bo[bufnr].modifiable = false
  end)
end

-- Insert the content at the cursor (insert mode)
function M.insert_response(content)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.split(content, "\n", { plain = true })
  local bufnr = vim.api.nvim_get_current_buf()

  local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = current_line:sub(1, col)
  local after = current_line:sub(col + 1)

  lines[1] = before .. lines[1]
  lines[#lines] = lines[#lines] .. after

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, lines)
end

-- Replace selected text (visual mode)
function M.replace_visual_selection(content)
  local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
  local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))
  local bufnr = vim.api.nvim_get_current_buf()

  if csrow > cerow or (csrow == cerow and cscol > cecol) then
    csrow, cerow = cerow, csrow
    cscol, cecol = cecol, cscol
  end

  local replacement = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, csrow - 1, cerow, false, replacement)
end

-- Prompt user for input
function M.input(prompt, callback)
  vim.ui.input({ prompt = prompt or "Input:" }, function(text)
    if text then callback(text) end
  end)
end

return M
