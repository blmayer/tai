-- Luacheck configuration for Tai project

-- Global variables from Neovim
std = "lua51"

-- Ignore warnings about unused global variables from Neovim
globals = {
  vim = true,
  package = true,
  _G = true,
  -- Allow unused arguments (common in Lua)
  unused_args = false,
  -- Allow redefined locals (common in tests)
  redefined = false,
  -- Allow setting non-standard globals (for tests)
  allow_defined = true,
  allow_defined_top = true,
}

-- Enable all warnings
warnings = {
  "all",
}

-- Disable specific warnings
no_max_line_length = false
no_unused_secondaries = false
