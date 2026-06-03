.PHONY: docs validate test test-ubuntu sync hooks

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

# Sync docs then validate
sync: docs validate

# Wire the pre-commit and pre-push hooks
hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/pre-commit .githooks/pre-push
	@echo "Pre-commit and pre-push hooks installed."
