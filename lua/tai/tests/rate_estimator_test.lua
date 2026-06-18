-- Test for the rate limiter's cost estimator
-- Run with: nvim --headless -u NONE -c "luafile lua/tai/tests/rate_estimator_test.lua" -c "qa"
-- or luajit lua/tai/tests/rate_estimator_test.lua (may need mocks for vim)

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Clear caches to force loading from current dir
package.loaded["tai.config"] = nil
package.loaded["tai.log"] = nil
package.loaded["tai.provider_common"] = nil
package.loaded["tai.providers"] = nil

local config = require('tai.config')
config.root = "/tmp/fake-tai-project"  -- dummy root so agent loads prompts

local agent = require('tai.agent')
local tools = require('tai.tools')

-- Use dofile to load the exact local providers.lua (bypasses any rtp/cached version)
local providers = dofile("./lua/tai/providers.lua")

-- Use the planner system prompt (the one used for initial calls)
-- plus the tools that planner has access to.
local planner_system = agent.planner_system_prompt

-- Planner tools (from ui.lua planner_config.tools)
local planner_tool_names = { "read", "shell", "send_image", "coder", "todos", "notes" }
local planner_tools = {}
for _, name in ipairs(planner_tool_names) do
  if tools.defs[name] then
    table.insert(planner_tools, tools.defs[name])
  end
end

-- Build a realistic initial request body (system + tools, no prior messages)
local body = {
  model = "mistral-small-latest",
  messages = {
    { role = "system", content = planner_system },
  },
  tools = planner_tools,
}

local estimated = providers.estimate_tokens_from_request_body(body)

print("Estimated tokens for system prompt + planner tools:", estimated)

-- User expects around 2230
local expected = 2230
local tolerance = 150  -- allow some variance due to date in prompt, json formatting, etc.
if math.abs(estimated - expected) > tolerance then
  error(string.format(
    "estimate_tokens_from_request_body gave %d, expected ~%d (tolerance %d)",
    estimated, expected, tolerance
  ))
else
  print("OK: within tolerance")
end
