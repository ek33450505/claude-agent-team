#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude/agent-status"

  # We'll test the bash snippet from SKILL.md directly
  # Extract and prepare it as a function for testing
  export TEST_STATUS_DIR="$HOME/.claude/agent-status"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Helper function: run the test-runner status file truth logic
# This extracts the bash snippet from SKILL.md and tests it
# ---------------------------------------------------------------------------

test_runner_file_truth() {
  # This replicates the Phase 4.11 bash snippet that checks test-runner status files
  # from ~/.claude/agent-status/test-runner-*.json
  local STATUS_FILE
  local FILE_MTIME
  local NOW
  local AGE
  local FILE_STATUS

  STATUS_FILE=$(python3 -c "
import os, glob, sys
files = glob.glob(os.path.join(os.environ.get('TEST_STATUS_DIR',''), 'test-runner-*.json'))
if files:
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    print(files[0])
" 2>/dev/null)

  if [[ -n "$STATUS_FILE" && -f "$STATUS_FILE" ]]; then
    FILE_MTIME=$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$STATUS_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$((NOW - FILE_MTIME))

    if [[ "$AGE" -le 300 ]]; then
      FILE_STATUS=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('status',''))" 2>/dev/null)
      echo "$FILE_STATUS"
      return 0
    else
      return 1  # File too old
    fi
  else
    return 1  # No file found
  fi
}

# ---------------------------------------------------------------------------
# Test 1: Recent status file (within 300s) is considered authoritative
# ---------------------------------------------------------------------------

@test "test-runner status file (recent, DONE) is considered authoritative" {
  # Write a fake test-runner status file with mtime = now
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  STATUS_FILE="$TEST_STATUS_DIR/test-runner-$(date +%s).json"

  cat > "$STATUS_FILE" <<EOF
{
  "status": "DONE",
  "ok_count": 958,
  "notok_count": 0,
  "agent": "test-runner",
  "summary": "All tests passed",
  "timestamp": "$TIMESTAMP"
}
EOF

  # Run the status file truth logic
  run test_runner_file_truth
  assert_success
  assert_output "DONE"
}

# ---------------------------------------------------------------------------
# Test 2: Stale status file (older than 300s) is NOT used
# ---------------------------------------------------------------------------

@test "test-runner status file older than 300s is NOT used" {
  # Write a test-runner status file with mtime 400s in the past
  STATUS_FILE="$TEST_STATUS_DIR/test-runner-old.json"

  cat > "$STATUS_FILE" <<EOF
{
  "status": "DONE",
  "ok_count": 958,
  "notok_count": 0,
  "agent": "test-runner",
  "summary": "Old result",
  "timestamp": "2026-05-11T00:00:00Z"
}
EOF

  # Set the file's mtime to 400 seconds in the past using Python
  python3 << PYEOF
import os
import time

file_path = "$STATUS_FILE"
past_time = time.time() - 400  # 400 seconds ago
os.utime(file_path, (past_time, past_time))
PYEOF

  # Run the status file truth logic — should fail because file is too old
  run test_runner_file_truth
  assert_failure  # File is stale, logic should return 1
}

# ---------------------------------------------------------------------------
# Test 3: Malformed JSON in status file is skipped safely
# ---------------------------------------------------------------------------

@test "test-runner status file with malformed JSON is skipped safely" {
  # Write a test-runner status file with invalid JSON
  STATUS_FILE="$TEST_STATUS_DIR/test-runner-broken.json"

  cat > "$STATUS_FILE" <<EOF
{
  "status": "DONE"
  "ok_count": 958,
  INVALID JSON HERE
}
EOF

  # Run the status file truth logic
  # It should exit gracefully (no crash, no recovered status)
  run test_runner_file_truth
  assert_success  # Snippet suppresses parse errors and returns cleanly
  # Output may be empty or contain no DONE/BLOCKED string — the key contract is "no crash"
  refute_output --partial "Traceback"
  refute_output --partial "JSONDecodeError"
}

# ---------------------------------------------------------------------------
# Test 4: Multiple status files — most recent is used
# ---------------------------------------------------------------------------

@test "test-runner selects most recent status file when multiple exist" {
  # Create two status files with different timestamps
  # The older one (90s ago) and the newer one (10s ago)

  OLD_FILE="$TEST_STATUS_DIR/test-runner-old-file.json"
  NEW_FILE="$TEST_STATUS_DIR/test-runner-new-file.json"

  cat > "$OLD_FILE" <<EOF
{
  "status": "BLOCKED",
  "ok_count": 900,
  "notok_count": 10,
  "agent": "test-runner",
  "summary": "Old result"
}
EOF

  cat > "$NEW_FILE" <<EOF
{
  "status": "DONE",
  "ok_count": 958,
  "notok_count": 0,
  "agent": "test-runner",
  "summary": "New result"
}
EOF

  # Set mtime: OLD_FILE = 90s ago, NEW_FILE = 10s ago
  python3 << PYEOF
import os
import time

now = time.time()
old_time = now - 90
new_time = now - 10

os.utime("$OLD_FILE", (old_time, old_time))
os.utime("$NEW_FILE", (new_time, new_time))
PYEOF

  # Run the status file truth logic — should pick the NEW_FILE (most recent)
  run test_runner_file_truth
  assert_success
  assert_output "DONE"  # From the newer file, not the older "BLOCKED"
}

# ---------------------------------------------------------------------------
# Test 5: No status file found
# ---------------------------------------------------------------------------

@test "test-runner returns failure when no status file exists" {
  # Ensure status dir is empty
  rm -f "$TEST_STATUS_DIR/test-runner-*.json"

  # Run the status file truth logic
  run test_runner_file_truth
  assert_failure
}
