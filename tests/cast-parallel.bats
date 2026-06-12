#!/usr/bin/env bats
# Tests for scripts/cast-parallel.sh
#
# Coverage:
#   - --help exits 0 and prints Usage
#   - missing plan file exits 2
#   - plan file with no ADM block exits 1
#   - --dry-run prints Stream A / Stream B and exits 0
#   - --split with invalid N exits non-zero
#   - --split N dry-run shows correct split

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_PARALLEL="$REPO_DIR/scripts/cast-parallel.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Fixture helper — creates a plan file with N batches
# ---------------------------------------------------------------------------

_make_fixture_plan() {
  local num_batches="${1:-4}"
  local plan_file="$HOME/test-plan.md"

  cat > "$plan_file" <<'HEADER'
# Test Plan

Some description.

```json dispatch
{
  "plan_id": "test-parallel-plan",
  "batches": [
HEADER

  for i in $(seq 1 "$num_batches"); do
    if [ "$i" -gt 1 ]; then
      printf ',\n' >> "$plan_file"
    fi
    cat >> "$plan_file" <<BATCH
    {
      "id": $i,
      "description": "Batch $i",
      "parallel": false,
      "agents": [
        {
          "subagent_type": "code-writer",
          "prompt": "Dummy prompt for batch $i"
        }
      ]
    }
BATCH
  done

  cat >> "$plan_file" <<'FOOTER'
  ]
}
```
FOOTER

  echo "$plan_file"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "--help exits 0 and prints Usage" {
  run bash "$CAST_PARALLEL" --help
  assert_success
  assert_output --partial 'Usage'
}

@test "missing plan file exits 2" {
  run bash "$CAST_PARALLEL"
  assert_failure
  [ "$status" -eq 2 ]
}

@test "plan file with no ADM block exits 1" {
  local plan_file="$HOME/empty-plan.md"
  printf '# No dispatch block here\nJust some text.\n' > "$plan_file"
  run bash "$CAST_PARALLEL" "$plan_file"
  assert_failure
  assert_output --partial 'No'
}

@test "--dry-run prints Stream A / Stream B and exits 0" {
  local plan_file
  plan_file="$(_make_fixture_plan 4)"
  run bash "$CAST_PARALLEL" --dry-run "$plan_file"
  assert_success
  assert_output --partial 'Stream A'
  assert_output --partial 'Stream B'
}

@test "--split with invalid N exits non-zero" {
  local plan_file
  plan_file="$(_make_fixture_plan 4)"

  # Split 0 is below minimum
  run bash "$CAST_PARALLEL" --split 0 --dry-run "$plan_file"
  assert_failure

  # Split 5 exceeds batch count of 4
  plan_file="$(_make_fixture_plan 4)"
  run bash "$CAST_PARALLEL" --split 5 --dry-run "$plan_file"
  assert_failure
}

@test "--split N dry-run shows correct split" {
  local plan_file
  plan_file="$(_make_fixture_plan 6)"
  run bash "$CAST_PARALLEL" --split 2 --dry-run "$plan_file"
  assert_success
  assert_output --partial 'Stream A (worktree-a): batches 1,2'
  assert_output --partial 'Stream B (worktree-b): batches 3,4,5,6'
}

@test "_db_log JSON builder emits parseable JSON with required routing_events fields" {
  # Test the JSON-building Python snippet used by _db_log in cast-parallel.sh.
  # This covers the fix: _db_log previously passed nonexistent --event/--message
  # flags; it now builds JSON via json.dumps and pipes to cast-db-log.py stdin.
  # We test the JSON-build leg in isolation using an isolated CAST_DB_PATH.

  local tmp_db_dir
  tmp_db_dir="$(mktemp -d)"
  export CAST_DB_PATH="$tmp_db_dir/t.db"
  bash "$REPO_DIR/scripts/cast-db-init.sh" 2>/dev/null

  # Build JSON the same way _db_log does (values via os.environ, json.dumps)
  local json_out
  json_out=$(
    CAST_DB_LOG_ACTION="parallel_start" \
    CAST_DB_LOG_MSG="BATS test message with 'quotes' and \"double\"" \
    CAST_DB_LOG_SESSION="bats-test-session" \
    CAST_DB_LOG_PROJECT="test-project" \
    python3 -c '
import json, os, datetime
print(json.dumps({
    "session_id":     os.environ["CAST_DB_LOG_SESSION"],
    "timestamp":      datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "prompt_preview": os.environ["CAST_DB_LOG_MSG"],
    "action":         os.environ["CAST_DB_LOG_ACTION"],
    "project":        os.environ["CAST_DB_LOG_PROJECT"],
}))'
  )

  # Must be valid JSON
  run python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['action'])" <<< "$json_out"
  assert_success
  assert_output "parallel_start"

  # Pipe to cast-db-log.py and assert a row lands in routing_events
  echo "$json_out" | python3 "$REPO_DIR/scripts/cast-db-log.py"
  run python3 -c "
import sqlite3, os
db = sqlite3.connect(os.environ['CAST_DB_PATH'])
rows = db.execute(\"SELECT action, session_id FROM routing_events WHERE action='parallel_start'\").fetchall()
print(len(rows))
"
  assert_success
  assert_output "1"

  rm -rf "$tmp_db_dir"
}
