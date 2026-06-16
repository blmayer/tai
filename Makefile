# Makefile for Tai project test framework

# Default target
all: test lint

# Install test dependencies via LuaRocks
install_deps:
	@echo "Installing Busted and Luacheck..."
	luarocks install busted
	luarocks install luacheck

# Run Busted tests
.PHONY: test-busted
test-busted:
	@echo "Running Busted tests..."
	busted lua/tai/spec

# Run custom/manual tests (these require a real Neovim instance)
.PHONY: test-custom
test-custom:
	@echo "Running custom tests (nvim headless)..."
	@for f in lua/tai/tests/*_test.lua; do \
		echo "  Running $$f"; \
		nvim --headless -u NONE --noplugin -c "luafile $$f" -c 'qa' || exit 1; \
	done
	@echo "Custom tests completed."

# Run all tests
.PHONY: test
test: test-busted test-custom
	@echo "All tests completed."

# Run Luacheck linting
.PHONY: lint

lint:
	@echo "Running Luacheck..."
	luacheck lua/tai

# Clean test artifacts
.PHONY: clean

clean:
	@echo "Cleaning test artifacts..."
	rm -rf lua/tai/spec/__busted_output
