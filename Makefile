PREFIX ?= $(HOME)/.local
JQ = jq
HERE = $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: test install

test:
	$(JQ) -e -n -L jq -f test/plan.test.jq >/dev/null
	$(JQ) -e -n -L jq -f test/fs.test.jq >/dev/null
	$(JQ) -e -n -L jq \
		--arg root /proj --arg op init --arg text '' --arg mcptext '' --arg image '' \
		--rawfile result /dev/null \
		--rawfile porch prompts/orchestrator.txt \
		--rawfile pnest prompts/orchestrator-nested.txt \
		--rawfile pman prompts/manager.txt \
		--rawfile pcoder prompts/coder.txt \
		--rawfile prev prompts/revisor.txt \
		--rawfile pguide prompts/guide.txt \
		--slurpfile cfg test/cfg.json \
		--slurpfile tools jq/tools.json \
		--slurpfile resp test/null.json \
		--slurpfile skills test/skills.json \
		-f test/harness.test.jq >/dev/null
	set -e; \
	share=$$(mktemp -d); \
	trap 'rm -rf "$$share"' EXIT; \
	mkdir -p "$$share/tai"; \
	ln -s "$$(pwd)/jq" "$$share/tai/jq"; \
	ln -s "$$(pwd)/prompts" "$$share/tai/prompts"; \
	XDG_DATA_HOME="$$share" ./tai --self-check
	sh test/emit.sh

install:
	mkdir -p $(PREFIX)/bin $(PREFIX)/share/tai/jq $(PREFIX)/share/tai/prompts
	install -m 755 tai $(PREFIX)/bin/tai
	install -m 644 jq/* $(PREFIX)/share/tai/jq/
	install -m 644 prompts/* $(PREFIX)/share/tai/prompts/
