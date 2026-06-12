#!/usr/bin/env bash
# Run all BATS tests — matches CI glob list exactly (BATS 1.13.0 is non-recursive)
# MANDATORY: runs against an isolated temp $HOME to prevent real ~/.claude damage
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Create isolated temp HOME + TAP capture file; register combined cleanup
TEST_HOME="$(mktemp -d)"
TAP_OUT="$(mktemp)"
trap 'rm -rf "$TEST_HOME" "$TAP_OUT"' EXIT

# Seed temp HOME with minimal CAST structure (mirrors CI setup)
mkdir -p "$TEST_HOME"/.claude/{scripts,logs,cast/events,agent-status}
cp "$REPO"/scripts/*.sh "$TEST_HOME"/.claude/scripts/
cp "$REPO"/scripts/*.py "$TEST_HOME"/.claude/scripts/ 2>/dev/null || true
chmod +x "$TEST_HOME"/.claude/scripts/*.sh

# Switch to isolated HOME and print banner
export HOME="$TEST_HOME"
echo "tests/run.sh: isolated temp HOME=$HOME — real ~/.claude untouched" >&2

# Expand the same glob list CI uses into an array for both counting and bats
BATS_FILE_ARGS=()
for _pat in tests/*.bats tests/hooks/*.bats tests/agents/*.bats tests/scripts/*.bats tests/skills/*.bats; do
  [[ -f "$_pat" ]] && BATS_FILE_ARGS+=("$_pat")
done

if [[ "${#BATS_FILE_ARGS[@]}" -eq 0 ]]; then
  echo "tests/run.sh: no .bats files found" >&2
  exit 1
fi

# Count planned tests statically from @test lines (before execution)
PLANNED="$("$REPO/scripts/cast-count-planned-tests.sh" "${BATS_FILE_ARGS[@]}")"

# Run BATS; stream output via tee so the user sees it live.
# stdout is a pipe here, so bats defaults to TAP formatter (readable + parseable).
# set +o pipefail: let tee succeed even when bats exits non-zero; capture via PIPESTATUS.
set +o pipefail
bats "${BATS_FILE_ARGS[@]}" "$@" | tee "$TAP_OUT"
BATS_EXIT="${PIPESTATUS[0]}"
set -o pipefail

# Parse executed count from TAP plan line (1..N)
EXECUTED="$(grep -m1 "^1\.\." "$TAP_OUT" | sed 's/^1\.\.//' | tr -d '[:space:]' || true)"
if [[ -z "$EXECUTED" ]]; then
  # Fallback: count ok / not ok result lines
  EXECUTED="$(grep -cE "^(ok|not ok) " "$TAP_OUT" 2>/dev/null || echo 0)"
fi

# Gate: fail loudly when executed != planned — detects dropped files or truncated runs.
# Skipped tests count as executed (ok N # skip); this catches only missing files.
if [[ "$EXECUTED" -ne "$PLANNED" ]]; then
  printf '\n[cast-count-gate] FAIL: planned=%s executed=%s\n' "$PLANNED" "$EXECUTED" >&2
  printf '  A test file may have been silently dropped from the run.\n' >&2
  exit 1
fi

exit "$BATS_EXIT"
