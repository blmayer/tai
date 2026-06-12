local config = require("tai.config")

-- Mock vim.fn for testing
vim.fn = {
  getcwd = function() return "/tmp/test_project" end,
  filereadable = function(path) return path == "/tmp/test_project/.tai" and 1 or 0 end,
  fnamemodify = function(path, mod) return path end,
}

-- Mock log module
package.loaded["tai.log"] = {
  debug = function() end,
}

describe("config module", function()
  before_each(function()
    -- Reset config state before each test
    config.root = "/tmp/test_project"
    config.provider_tools = nil
    config.rpm = 60
    config.tpm = nil
    config.default_allowed_commands = {
      cat = true,
      grep = true,
      ag = true,
      rg = true,
      ls = true,
      head = true,
      tail = true,
      wc = true,
      diff = true,
      sort = true,
      uniq = true,
      find = true,
      file = true,
      stat = true,
      date = true,
      echo = true,
      tree = true,
      pwd = true,
      which = true,
      type = true,
    }
  end)

  describe("reload", function()
    it("should reload config from .tai file", function()
      -- Mock .tai file content
      local mock_file = {
        model = "test-model",
        provider = "test-provider",
        use_tools = false,
        options = { test = true },
        stream = true,
        allowed_commands = { ls = false },
        think = true,
        provider_tools = { web_browser = true },
        system_prompt = "test prompt",
        custom_prompt = "custom",
        rpm = 120,
        tpm = 1000,
      }
      
      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "/tmp/test_project/.tai" and mode == "r" then
          return {
            read = function() return vim.fn.json_encode(mock_file) end,
            close = function() end,
          }
        end
        return original_open(path, mode)
      end

      local ok, err = config.reload()
      assert.is_true(ok)
      assert.is_nil(err)
      assert.are.equal("test-model", config.model)
      assert.are.equal("test-provider", config.provider)
      assert.is_false(config.use_tools)
      assert.are.same({ test = true }, config.options)
      assert.is_true(config.stream)
      assert.are.same({ ls = false }, config.allowed_commands)
      assert.is_true(config.think)
      assert.are.same({ web_browser = true }, config.provider_tools)
      assert.are.equal("test prompt", config.system_prompt)
      assert.are.equal("custom", config.custom_prompt)
      assert.are.equal(120, config.rpm)
      assert.are.equal(1000, config.tpm)

      -- Restore io.open
      io.open = original_open
    end)

    it("should use defaults when .tai file is missing", function()
      -- Mock io.open to return nil (file not found)
      local original_open = io.open
      io.open = function(path, mode)
        return nil
      end

      local ok, err = config.reload()
      assert.is_false(ok)
      assert.are.equal("failed to open .tai", err)

      -- Restore io.open
      io.open = original_open
    end)
  end)

  describe("get_allowed_commands", function()
    it("should return default allowed commands when none are set", function()
      config.allowed_commands = nil
      local allowed = config.get_allowed_commands()
      assert.are.same(config.default_allowed_commands, allowed)
    end)

    it("should return custom allowed commands when set", function()
      config.allowed_commands = { ls = false, cat = true }
      local allowed = config.get_allowed_commands()
      assert.are.same({ ls = false, cat = true }, allowed)
    end)
  end)
end)
