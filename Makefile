.PHONY: docs validate test sync hooks

# Regenerate README stats from live counts
docs:
	bash scripts/gen-stats.sh

# Run CAST validation script (checks installed config integrity)
validate:
	@if [ -f scripts/cast-validate.sh ]; then \
		bash scripts/cast-validate.sh; \
	elif [ -f ~/.claude/scripts/cast-validate.sh ]; then \
		bash ~/.claude/scripts/cast-validate.sh; \
	else \
		echo "cast-validate.sh not found — run ./install.sh first"; \
		exit 1; \
	fi

# Run the full BATS test suite
test:
	tests/bats/bin/bats tests/*.bats

# Sync docs then validate
sync: docs validate

# Wire the pre-commit hook (alternative to running ./install.sh)
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit
	@echo "Pre-commit hook installed."
