# Makefile for Tai project test framework

# Default target
all: test lint

# Install test dependencies via LuaRocks
install_deps:
	@echo "Installing Busted and Luacheck..."
	luarocks install busted
	luarocks install luacheck

# Run Busted tests
.PHONY: test

test:
	@echo "Running Busted tests..."
	busted lua/tai/spec

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
