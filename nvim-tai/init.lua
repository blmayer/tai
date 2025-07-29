local M = {}

function M.setup()
  require("tai.project").init_project_prompt()
  require("tai.keymaps").setup()
end

return M

