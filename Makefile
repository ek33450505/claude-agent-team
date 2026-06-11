.PHONY: docs validate test test-ubuntu ci-local sync hooks

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
	bats tests/*.bats tests/hooks/*.bats tests/agents/*.bats tests/scripts/*.bats

# Run BATS in Docker Ubuntu container (mirrors CI environment)
test-ubuntu:
	@echo "Running BATS in Docker Ubuntu (mirrors CI)..."
	docker build -f Dockerfile.ci -t cast-ci-ubuntu . --quiet
	# SAFETY: never mount the host ~/.claude into this container. A destructive test wiped the
	# maintainer's live runtime through exactly that mount (audit §3.8.B). The container builds its
	# own ephemeral ~/.claude from /repo below; it must have zero access to the host runtime.
	docker run --rm \
	  -v "$(PWD):/repo" \
	  cast-ci-ubuntu bash -c " \
	    mkdir -p ~/.claude/scripts ~/.claude/logs ~/.claude/cast/events ~/.claude/agent-status && \
	    cp /repo/scripts/*.sh ~/.claude/scripts/ && \
	    cp /repo/scripts/*.py ~/.claude/scripts/ && \
	    chmod +x ~/.claude/scripts/*.sh && \
	    bats /repo/tests/*.bats /repo/tests/hooks/*.bats /repo/tests/agents/*.bats /repo/tests/scripts/*.bats --tap \
	  "

# Run real GitHub Actions CI locally via act (simulates PR event)
# Requires: act (https://nektosact.com) and Docker
#
# Jobs included (mirrors the full PR-gating workflow set):
#   bats, contract-test, hook-contract-validation — bats-ci.yml (full suite + contracts)
#   stats-guard           — cast-stats-guard.yml
#   rules-drift           — rules-drift.yml
#   readme-structure      — docs-check.yml
#   pii-scan, shellcheck  — security-scan.yml
#   db-contract           — db-contract.yml
#
# Runner image: -P pins ubuntu-latest to catthehacker/ubuntu:act-latest so act never
#   prompts interactively on first run (non-TTY safe; equivalent to the prompt's default).
#
# Excluded (cannot run under act):
#   gitleaks   — uses gitleaks/gitleaks-action which requires a live GITHUB_TOKEN secret;
#                run the local equivalent manually: bash scripts/ci-pii-scan.sh
#   bats-macos — act cannot run macOS runners (macos-latest); covered by: make test
#   bats-ubuntu — duplicates the bats job's full-suite run on ubuntu-latest; expensive
ci-local:
	@command -v act >/dev/null || { \
		echo "Error: act not found. Install from https://nektosact.com"; \
		exit 1; \
	}
	@docker info >/dev/null 2>&1 || { \
		echo "Error: Docker daemon not running. Start Docker and retry."; \
		exit 1; \
	}
	@echo "Running PR-gating workflows locally via act..."
	@echo "This simulates the exact CI checks that block PR merges."
	@echo ""
	act pull_request --container-architecture linux/amd64 \
	  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
	  -j bats -j contract-test -j hook-contract-validation \
	  -j stats-guard -j rules-drift -j readme-structure \
	  -j pii-scan -j shellcheck -j db-contract

# Sync docs then validate
sync: docs validate

# Wire the pre-commit and pre-push hooks
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit .githooks/pre-push
	@echo "Pre-commit and pre-push hooks installed."
