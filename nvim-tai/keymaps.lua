local M = {}

function M.setup()
  local tai = require("tai.handlers")
  local ops = require("tai.ops")

  vim.keymap.set("n", "<leader>ti", tai.prompt_input, { desc = "Tai prompt" })
  vim.keymap.set("n", "<leader>tc", tai.insert_response, { desc = "Tai insert mode append" })

  vim.keymap.set("n", "gT", function()
    vim.cmd('set operatorfunc=v:lua.require"tai.ops".send')
    vim.api.nvim_feedkeys("g@", "n", false)
  end, { noremap = true })

  vim.keymap.set("n", "gP", function()
    vim.cmd('set operatorfunc=v:lua.require"tai.ops".send_with_prompt')
    vim.api.nvim_feedkeys("g@", "n", false)
  end, { noremap = true })
end

return M

