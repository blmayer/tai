local tools = require("tai.tools")
local config = require("tai.config")

-- Mock vim.fn for testing
vim.fn = {
  filereadable = function(path) return path == "test.txt" and 1 or 0 end,
  fnamemodify = function(path, mod) return path end,
  isdirectory = function(path) return path == "/tmp" and 1 or 0 end,
}

-- Mock vim.api for testing
vim.api = {
  nvim_get_current_buf = function() return 1 end,
  nvim_buf_get_lines = function(buf, start, end_, strict) return { "line1", "line2", "line3" } end,
  nvim_buf_set_lines = function(buf, start, end_, strict, lines) end,
  nvim_buf_call = function(buf, func) func() end,
}

-- Mock vim.cmd for testing
vim.cmd = function(cmd) end

-- Mock log module
package.loaded["tai.log"] = {
  debug = function() end,
}

-- Mock os.getenv for testing
os.getenv = function(name) return name == "PATH" and "/usr/bin" or nil end

-- Mock io.popen for testing
local mock_popen = {
  read = function() return "output" end,
  close = function() end,
}

-- Mock io.open for testing
local mock_io_open = {
  read = function() return "content" end,
  close = function() end,
}

describe("tools module", function()
  before_each(function()
    -- Reset tools state before each test
    tools.todos_store = {}
    tools.todos_next_id = 1
    tools.notes_store = ""
    
    -- Reset config state
    config.allowed_commands = nil
  end)

  describe("read_file", function()
    it("should return error for root paths", function()
      local result = tools.read_file("/test.txt")
      assert.are.equal("Paths cannot start from root (/). Use relative.", result)
    end)

    it("should return error for non-existent files", function()
      local result = tools.read_file("nonexistent.txt")
      assert.are.match("File `nonexistent.txt` not found", result)
    end)

    it("should return numbered content for existing files", function()
      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "test.txt" and mode == "r" then
          return mock_io_open
        end
        return original_open(path, mode)
      end

      -- Mock vim.split to return lines
      local original_split = vim.split
      vim.split = function(content, sep, opts)
        return { "line1", "line2", "line3" }
      end

      local result = tools.read_file("test.txt")
      assert.are.equal("1: line1\n2: line2\n3: line3", result)

      -- Restore functions
      io.open = original_open
      vim.split = original_split
    end)

    it("should return numbered content for specific range", function()
      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "test.txt" and mode == "r" then
          return mock_io_open
        end
        return original_open(path, mode)
      end

      -- Mock vim.split to return lines
      local original_split = vim.split
      vim.split = function(content, sep, opts)
        return { "line1", "line2", "line3", "line4", "line5" }
      end

      local result = tools.read_file("test.txt", "2:4")
      assert.are.equal("2: line2\n3: line3\n4: line4", result)

      -- Restore functions
      io.open = original_open
      vim.split = original_split
    end)
  end)

  describe("unsafe_command", function()
    it("should allow allowed commands", function()
      config.allowed_commands = { ls = true, cat = true }
      local result = tools.unsafe_command("ls -la")
      assert.is_false(result)
    end)

    it("should disallow disallowed commands", function()
      config.allowed_commands = { ls = true, cat = false }
      local result = tools.unsafe_command("cat file.txt")
      assert.are.equal("Command cat is not allowed.", result)
    end)

    it("should disallow commands with redirects", function()
      local result = tools.unsafe_command("ls > file.txt")
      assert.are.equal("[sys] Redirects (>, <, >>, <<, etc.) are not allowed.", result)
    end)
  end)

  describe("exec_command", function()
    it("should execute allowed commands", function()
      -- Mock io.popen to return our mock popen
      local original_popen = io.popen
      io.popen = function(cmd, mode)
        return mock_popen
      end

      local output, err = tools.exec_command("ls -la")
      assert.is_nil(err)
      assert.are.equal("output", output)

      -- Restore io.popen
      io.popen = original_popen
    end)

    it("should return error for failed commands", function()
      -- Mock io.popen to return nil
      local original_popen = io.popen
      io.popen = function(cmd, mode)
        return nil
      end

      local output, err = tools.exec_command("invalid_command")
      assert.is_nil(output)
      assert.are.equal("Failed to run command", err)

      -- Restore io.popen
      io.popen = original_popen
    end)
  end)

  describe("write", function()
    it("should return error for root paths", function()
      local result = tools.write("/test.txt", "content")
      assert.are.equal("Paths cannot start from root (/). Use relative.", result)
    end)

    it("should create file in existing directory", function()
      -- Mock vim.fn.mkdir to return 1 (success)
      local original_mkdir = vim.fn.mkdir
      vim.fn.mkdir = function(dir, flags) return 1 end

      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "test.txt" and mode == "w" then
          return {
            write = function() end,
            close = function() end,
          }
        end
        return original_open(path, mode)
      end

      local result = tools.write("test.txt", "content")
      assert.are.equal("File created: test.txt", result)

      -- Restore functions
      vim.fn.mkdir = original_mkdir
      io.open = original_open
    end)

    it("should create parent directory if needed", function()
      -- Mock vim.fn.mkdir to return 1 (success)
      local original_mkdir = vim.fn.mkdir
      vim.fn.mkdir = function(dir, flags) return 1 end

      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "subdir/test.txt" and mode == "w" then
          return {
            write = function() end,
            close = function() end,
          }
        end
        return original_open(path, mode)
      end

      local result = tools.write("subdir/test.txt", "content")
      assert.are.equal("File created: subdir/test.txt", result)

      -- Restore functions
      vim.fn.mkdir = original_mkdir
      io.open = original_open
    end)
  end)

  describe("edit", function()
    it("should return error for root paths", function()
      local result = tools.edit("/test.txt", "old", "new")
      assert.are.equal("Paths cannot start from root (/). Use relative.", result)
    end)

    it("should return error for non-existent files", function()
      local result = tools.edit("nonexistent.txt", "old", "new")
      assert.are.match("File not found: nonexistent.txt", result)
    end)

    it("should edit file with old_text and new_text", function()
      -- Mock vim.fn.filereadable to return 1 (file exists)
      local original_filereadable = vim.fn.filereadable
      vim.fn.filereadable = function(path) return 1 end

      -- Mock io.open to return our mock file
      local original_open = io.open
      io.open = function(path, mode)
        if path == "test.txt" and mode == "r" then
          return mock_io_open
        end
        return original_open(path, mode)
      end

      local result = tools.edit("test.txt", "line1", "new line")
      assert.are.equal("Patched test.txt", result)

      -- Restore functions
      vim.fn.filereadable = original_filereadable
      io.open = original_open
    end)
  end)

  describe("run_todos", function()
    it("should add todo items", function()
      local result = tools.run_todos({ action = "add", text = "Test todo" })
      assert.are.match("Added todo #%d+: %[pending%] Test todo", result)
    end)

    it("should update todo items", function()
      -- Add a todo first
      tools.run_todos({ action = "add", text = "Test todo" })
      
      -- Update it
      local result = tools.run_todos({ action = "update", id = 1, status = "done" })
      assert.are.match("Updated todo #1: %[done%] Test todo", result)
    end)

    it("should list todo items", function()
      -- Add a todo first
      tools.run_todos({ action = "add", text = "Test todo" })
      
      -- List it
      local result = tools.run_todos({ action = "list" })
      assert.are.match("#1 %[pending%] Test todo", result)
    end)
  end)

  describe("run_notes", function()
    it("should write notes", function()
      local result = tools.run_notes({ action = "write", content = "Test note" })
      assert.are.equal("Notes updated.", result)
      assert.are.equal("Test note", tools.notes_store)
    end)

    it("should append notes", function()
      tools.notes_store = "Initial note"
      local result = tools.run_notes({ action = "append", content = "Appended note" })
      assert.are.equal("Notes appended.", result)
      assert.are.equal("Initial note\nAppended note", tools.notes_store)
    end)

    it("should read notes", function()
      tools.notes_store = "Test note"
      local result = tools.run_notes({ action = "read" })
      assert.are.equal("Test note", result)
    end)
  end)
end)
