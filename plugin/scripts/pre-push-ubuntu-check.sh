#!/usr/bin/env bash
# Pre-push check: run BATS in Ubuntu Docker before pushing
# Wire with: git config core.hooksPath .githooks && add to .githooks/pre-push
# Exit code: 0 (pass or Docker not available), non-zero (test failure)

set -euo pipefail

# Opt-out: skip the (slow) Docker Ubuntu parity check. Used by tests that exercise
# other parts of the pre-push hook, and by users who don't want it on every push.
if [ "${CAST_SKIP_UBUNTU_CHECK:-0}" = "1" ]; then
  echo "[CAST] Ubuntu CI parity check skipped (CAST_SKIP_UBUNTU_CHECK=1)." >&2
  exit 0
fi

if ! command -v docker &>/dev/null; then
  echo "[CAST] Docker not found — skipping Ubuntu CI parity check. Install Docker to enable." >&2
  exit 0
fi

if ! docker info &>/dev/null 2>&1; then
  echo "[CAST] Docker daemon not running — skipping Ubuntu CI parity check." >&2
  exit 0
fi

echo "[CAST] Running Ubuntu CI parity check via Docker..."
make test-ubuntu
