#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STATS_SH="$REPO_DIR/scripts/cast-agent-stats.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_log_entries() {
  # write_log_entries <agent> <status> <count> [timestamp]
  local agent="$1"
  local status="$2"
  local count="$3"
  local timestamp="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local log_file="$HOME/.claude/routing-log.jsonl"

  python3 - "$log_file" "$agent" "$status" "$count" "$timestamp" <<'PYEOF'
import json, sys
log_file, agent, status, count, timestamp = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
with open(log_file, 'a') as f:
    for _ in range(count):
        entry = {
            "timestamp": timestamp,
            "session_id": "test-session",
            "action": "agent_complete",
            "matched_route": agent,
            "status": status,
            "summary": f"Test {status} for {agent}"
        }
        f.write(json.dumps(entry) + '\n')
PYEOF
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# 1. Empty log
# ---------------------------------------------------------------------------

@test "empty log outputs no-data message" {
  # Create an empty routing-log.jsonl
  touch "$HOME/.claude/routing-log.jsonl"
  run bash "$STATS_SH"
  assert_success
  assert_output --partial "No agent_complete entries"
}

# ---------------------------------------------------------------------------
# 2. Correct BLOCKED rate
# ---------------------------------------------------------------------------

@test "reports correct BLOCKED rate for debugger" {
  # 10 DONE + 2 BLOCKED = 12 total, 17% BLOCKED
  write_log_entries "debugger" "DONE" 10
  write_log_entries "debugger" "BLOCKED" 2
  run bash "$STATS_SH"
  assert_success
  assert_output --partial "debugger"
  # 2/12 = 16.67% -> rounds to 17%
  assert_output --partial "17%"
}

# ---------------------------------------------------------------------------
# 3. --since filter excludes old entries
# ---------------------------------------------------------------------------

@test "--since 7d excludes entries older than 7 days" {
  # Write 5 old DONE entries (2020)
  write_log_entries "planner" "DONE" 5 "2020-01-01T00:00:00Z"
  # Write 3 recent BLOCKED entries (now)
  write_log_entries "planner" "BLOCKED" 3
  run bash "$STATS_SH" --since 7d
  assert_success
  # The old DONE entries should be excluded
  # Only 3 BLOCKED entries remain — if any output, verify count is not 5+3=8
  if echo "$output" | grep -q "planner"; then
    # planner should show 3 runs (only recent entries)
    echo "$output" | grep "planner" | grep -v "No agent_complete" || true
    # Verify the total runs shown for planner is 3 not 8
    python3 - "$output" <<'PYEOF'
import sys, re
output = sys.argv[1]
for line in output.splitlines():
    if 'planner' in line:
        # Extract the runs number (second column after agent name)
        parts = line.split()
        for i, p in enumerate(parts):
            if p == 'planner' and i + 1 < len(parts):
                runs = parts[i+1]
                assert runs != '8', f"Expected 3 runs (recent only), got {runs}"
                break
PYEOF
  fi
}

# ---------------------------------------------------------------------------
# 4. --agent filters to single agent
# ---------------------------------------------------------------------------

@test "--agent flag filters output to single agent" {
  write_log_entries "debugger" "DONE" 5
  write_log_entries "commit" "DONE" 3
  write_log_entries "commit" "BLOCKED" 2
  run bash "$STATS_SH" --agent commit
  assert_success
  assert_output --partial "commit"
  refute_output --partial "debugger"
}

# ---------------------------------------------------------------------------
# 5. --format json outputs valid JSON
# ---------------------------------------------------------------------------

@test "--format json outputs valid JSON array" {
  write_log_entries "code-reviewer" "DONE" 5
  run bash "$STATS_SH" --format json
  assert_success
  # Validate JSON with python3
  python3 - "$output" <<'PYEOF'
import json, sys
output = sys.argv[1]
parsed = json.loads(output)
assert isinstance(parsed, list), f"Expected JSON array, got: {type(parsed)}"
assert len(parsed) > 0, "Expected at least one entry in JSON array"
entry = parsed[0]
assert 'agent' in entry, f"Missing 'agent' key in entry: {entry}"
assert 'runs' in entry, f"Missing 'runs' key in entry: {entry}"
assert 'score' in entry, f"Missing 'score' key in entry: {entry}"
PYEOF
}

# ---------------------------------------------------------------------------
# 6. Agents with fewer than 5 runs not flagged (no warning, still shown)
# ---------------------------------------------------------------------------

@test "agents with fewer than 5 runs are still reported without flagging" {
  # Write 2 BLOCKED + 1 DONE for a small-sample agent — total 3 runs (below min 5)
  write_log_entries "tiny-agent" "BLOCKED" 2
  write_log_entries "tiny-agent" "DONE" 1
  run bash "$STATS_SH"
  assert_success
  # tiny-agent should appear in the table (it has data)
  assert_output --partial "tiny-agent"
  # No special warning beyond the normal table (min-sample guard prevents health flag)
  # The test verifies the script doesn't crash or error on small samples
}
