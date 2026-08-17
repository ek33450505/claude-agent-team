.PHONY: docs validate test test-ubuntu ci-local sync hooks ecosystem-versions

# Regenerate README stats and ecosystem versions from live counts
docs:
	bash scripts/gen-stats.sh
	bash scripts/gen-ecosystem-versions.sh

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
# Jobs included via act (mirrors the full PR-gating workflow set, minus what's
# run directly below):
#   bats                   — bats-ci.yml (full suite)
#   stats-guard            — cast-stats-guard.yml
#   rules-drift            — rules-drift.yml
#   readme-structure       — docs-check.yml
#   pii-scan, shellcheck   — security-scan.yml
#   db-contract            — db-contract.yml
#   self-lints             — self-lints.yml
# Plus, run directly (not via act — see "Dropped from the act loop" below),
# BOTH before the act loop so a later act-job failure can never silently
# skip either of them:
#   hook-contract-validation — scripts/cast-validate-all-hooks.sh --source
#   python-unit               — python3 -m unittest discover -s tests -p
#                              'test_*.py' -v (the exact python-unit.yml
#                              command)
#
# Runner image: -P pins ubuntu-latest to catthehacker/ubuntu:act-latest so act never
#   prompts interactively on first run (non-TTY safe; equivalent to the prompt's default).
#
# One invocation per job: act's -j flag is last-wins (repeated -j silently runs only the
#   final job). Use a fail-fast loop — one act call per job — to guarantee all 8 run.
#
# Dropped from the act loop:
#   contract-test            — advisory-only BY CONSTRUCTION: `bats-ci.yml` runs it as
#                              `... || true` with `continue-on-error: true`, and the
#                              workflow's own comment says it "currently provides no
#                              enforcement signal" (fixture coverage incomplete). It cannot
#                              fail a PR, so skipping it here loses no real signal.
#   hook-contract-validation — a REAL gate, so it is NOT skipped: it runs directly ABOVE
#                              the act loop (not after — see below), as
#                              `scripts/cast-validate-all-hooks.sh --source` (the same
#                              command bats-ci.yml's job runs), instead of paying the
#                              `needs: bats` re-run cost under act. It used to run directly
#                              but AFTER the act loop; when an earlier act job failed, the
#                              loop's `exit 1` aborted `make` before this gate ever ran —
#                              the only coverage for hook contracts in ci-local silently
#                              skipped. Moving it before the loop, with its own unconditional
#                              failure path, closes that gap (LF-9, 2026-08-16).
#   python-unit               — moved out of the act loop entirely, not just reordered:
#                              PyYAML is absent from the act image
#                              (catthehacker/ubuntu:act-latest) but present on GitHub's
#                              ubuntu-latest, so this job is permanently red under act on
#                              this machine for a reason unrelated to real regressions.
#                              Runs directly above as the workflow's exact command instead.
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
	@echo "Skipping via act (see Makefile header): contract-test (advisory-only, no enforcement signal)."
	@echo "── ci-local: direct job hook-contract-validation (run BEFORE the act loop — needs: bats would re-run the whole suite under act, and running it after the loop let a mid-loop failure skip it silently)"
	bash scripts/cast-validate-all-hooks.sh --source
	@echo "── ci-local: direct job python-unit (run directly — PyYAML is absent from the act image but present on GitHub's ubuntu-latest)"
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	@for j in bats stats-guard rules-drift readme-structure pii-scan shellcheck db-contract self-lints; do \
		echo "── ci-local: act job $$j"; \
		act pull_request --container-architecture linux/amd64 -P ubuntu-latest=catthehacker/ubuntu:act-latest -j "$$j" || { echo "ci-local FAILED at job: $$j" >&2; exit 1; }; \
	done
	@echo "ci-local: hook-contract-validation + python-unit (direct, before the loop) + 8 act jobs green"

# Sync docs then validate
sync: docs validate

# Wire the pre-commit and pre-push hooks
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit .githooks/pre-push
	@echo "Pre-commit and pre-push hooks installed."

# Regenerate ecosystem-versions.json from local sibling repos
ecosystem-versions:
	bash scripts/gen-ecosystem-versions.sh
