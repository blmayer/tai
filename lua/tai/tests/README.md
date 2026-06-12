# Tai Test Framework

This directory contains tests for the Tai Neovim plugin.

## Test Structure

- Tests are written using the **Busted** framework.
- Test files are located in `lua/tai/spec/` and mirror the structure of `lua/tai/`.
- Example: `lua/tai/spec/config_spec.lua` tests `lua/tai/config.lua`.

## Running Tests

### Prerequisites
- [LuaRocks](https://luarocks.org/) (for installing Busted and Luacheck)
- [Busted](https://olivinelabs.com/busted/) (Lua testing framework)
- [Luacheck](https://github.com/lunarmodules/luacheck) (Lua linter)

### Install Dependencies
```sh
make install_deps
```

### Run Tests
```sh
make test
```

### Run Linting
```sh
make lint
```

### Run All Checks
```sh
make all
```

## Writing New Tests

1. Create a new file in `lua/tai/spec/` (e.g., `new_module_spec.lua`).
2. Use the Busted syntax:
   ```lua
   describe("module name", function()
     it("should do something", function()
       assert.is_true(true)
     end)
   end)
   ```
3. Mock Neovim globals (e.g., `vim.fn`, `vim.api`) as needed.
4. Add your test file to version control.

## Mocking Neovim APIs

Common mocks are already provided in test files. For advanced mocking, see the [Busted documentation](https://olivinelabs.com/busted/#documentation).

## Example Test

See `lua/tai/spec/config_spec.lua` and `lua/tai/spec/tools_spec.lua` for examples.
