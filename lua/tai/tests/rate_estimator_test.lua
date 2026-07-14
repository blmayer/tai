-- Manual smoke test for request token estimation.
-- Run: nvim --headless -u NONE -c "set rtp+=." -c "luafile lua/tai/tests/rate_estimator_test.lua" -c "qa!"

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Minimal stubs if not inside Neovim
if not vim then
  error("Run this test with nvim --headless")
end

local ok_config, config = pcall(require, "tai.config")
if not ok_config or not config.root then
  print("SKIP: no .tai project root")
  return
end

local agent = require("tai.agent")
local tools = require("tai.tools")
local providers = require("tai.providers")

local main = agent.profiles.main
local tool_list = {}
for _, name in ipairs(main.tools) do
  if tools.defs[name] then
    table.insert(tool_list, tools.defs[name])
  end
end

local body = {
  model = "test",
  messages = {
    { role = "system", content = main.prompt },
  },
  tools = tool_list,
}

local estimated = providers.estimate_tokens_from_request_body(body)
print("Estimated tokens for main system prompt + tools:", estimated)
print("OK")
