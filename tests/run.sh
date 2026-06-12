#!/usr/bin/env bash
# Run all BATS tests — matches CI glob list exactly (BATS 1.13.0 is non-recursive)
# MANDATORY: runs against an isolated temp $HOME to prevent real ~/.claude damage
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Create isolated temp HOME and register cleanup
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

# Seed temp HOME with minimal CAST structure (mirrors CI setup)
mkdir -p "$TEST_HOME"/.claude/{scripts,logs,cast/events,agent-status}
cp "$REPO"/scripts/*.sh "$TEST_HOME"/.claude/scripts/
cp "$REPO"/scripts/*.py "$TEST_HOME"/.claude/scripts/ 2>/dev/null || true
chmod +x "$TEST_HOME"/.claude/scripts/*.sh

# Switch to isolated HOME and print banner
export HOME="$TEST_HOME"
echo "tests/run.sh: isolated temp HOME=$HOME — real ~/.claude untouched" >&2

# Run BATS with the same glob list as CI
bats tests/*.bats tests/hooks/*.bats tests/agents/*.bats tests/scripts/*.bats tests/skills/*.bats "$@"
exit "$?"
