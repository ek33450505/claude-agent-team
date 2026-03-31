#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STATS_SH="$REPO_DIR/scripts/cast-stats.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/cast/events"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# --brief mode
# ---------------------------------------------------------------------------

@test "--brief outputs CAST status line even when routing-log.jsonl is absent" {
  # routing-log.jsonl does NOT exist — the old code would have printed "CAST ready"
  # and exited; the fix must still produce the full status line format.
  run bash "$STATS_SH" --brief
  assert_success
  assert_output --partial "CAST |"
  assert_output --partial "agents:"
  assert_output --partial "dispatches:"
  assert_output --partial "log:"
}

@test "--brief counts agents_today from subagent-stop events for today" {
  TODAY=$(date +%Y%m%d)
  # Create two synthetic subagent-stop event files for today
  touch "$HOME/.claude/cast/events/${TODAY}T100000Z-subagent-stop.json"
  touch "$HOME/.claude/cast/events/${TODAY}T110000Z-subagent-stop.json"
  # Create one for a different day — should NOT be counted
  touch "$HOME/.claude/cast/events/20200101T120000Z-subagent-stop.json"

  run bash "$STATS_SH" --brief
  assert_success
  assert_output --partial "agents:2 today"
}

@test "--brief counts all-time dispatches from subagent-stop events" {
  TODAY=$(date +%Y%m%d)
  # Three events total — two today, one old — all count toward dispatches
  touch "$HOME/.claude/cast/events/${TODAY}T100000Z-subagent-stop.json"
  touch "$HOME/.claude/cast/events/${TODAY}T110000Z-subagent-stop.json"
  touch "$HOME/.claude/cast/events/20200101T120000Z-subagent-stop.json"

  run bash "$STATS_SH" --brief
  assert_success
  assert_output --partial "dispatches:3"
}

@test "--brief shows 0.0MB log size when no cast jsonl files exist" {
  # ~/.claude/cast/ exists but has no *.jsonl files
  run bash "$STATS_SH" --brief
  assert_success
  assert_output --partial "log: 0.0MB"
}

@test "--brief reflects log size from cast/*.jsonl files" {
  # Write 1 MiB of data into a cast jsonl file so we can verify sizing
  dd if=/dev/zero bs=1048576 count=1 2>/dev/null > "$HOME/.claude/cast/tool-failures.jsonl"

  run bash "$STATS_SH" --brief
  assert_success
  assert_output --partial "log: 1.0MB"
}

@test "--brief status line does not show 'CAST ready' when routing-log.jsonl is absent" {
  # Regression: old code exited with "CAST ready" whenever the routing log was missing.
  # The file was migrated to SQLite and is now permanently absent. The fix removes
  # this early exit so the full status line always appears.
  run bash "$STATS_SH" --brief
  assert_success
  refute_output --partial "CAST ready"
}
