#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_EVENTS_SH="$REPO_DIR/scripts/cast-events.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"

  # Override all CAST dirs to use the temp home so we never touch ~/.claude
  export CAST_DIR="$HOME/.claude/cast"
  export CAST_EVENTS_DIR="$CAST_DIR/events"
  export CAST_STATE_DIR="$CAST_DIR/state"
  export CAST_REVIEWS_DIR="$CAST_DIR/reviews"
  export CAST_ARTIFACTS_DIR="$CAST_DIR/artifacts"

  # Source the library — functions become available in the shell used by `run`
  # shellcheck source=/dev/null
  source "$CAST_EVENTS_SH"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Helper: read JSON field from a file
# ---------------------------------------------------------------------------

json_field() {
  local file="$1"
  local field="$2"
  python3 -c "import json; d=json.load(open('$file')); print(d.get('$field',''))"
}

# ---------------------------------------------------------------------------
# 1. cast_emit_event
# ---------------------------------------------------------------------------

@test "cast_emit_event: creates a file in events/ directory" {
  cast_emit_event "task_created" "orchestrator" "batch-1" "" "Planning batch" "" ""
  local count
  count=$(ls -1 "$CAST_EVENTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "cast_emit_event: event file contains correct event_type" {
  cast_emit_event "task_claimed" "planner" "task-42" "" "Claimed" "" ""
  local file
  file=$(ls -1t "$CAST_EVENTS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "event_type")
  [ "$val" = "task_claimed" ]
}

@test "cast_emit_event: event file contains correct agent" {
  cast_emit_event "task_completed" "test-writer" "task-99" "" "Done" "DONE" ""
  local file
  file=$(ls -1t "$CAST_EVENTS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "agent")
  [ "$val" = "test-writer" ]
}

@test "cast_emit_event: event file contains correct task_id" {
  cast_emit_event "task_blocked" "debugger" "my-task-id" "" "Blocked" "BLOCKED" "npm missing"
  local file
  file=$(ls -1t "$CAST_EVENTS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "task_id")
  [ "$val" = "my-task-id" ]
}

@test "cast_emit_event: event file contains a timestamp field" {
  cast_emit_event "artifact_written" "refactor-cleaner" "task-5" "art-1" "Wrote patch" "" ""
  local file
  file=$(ls -1t "$CAST_EVENTS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "timestamp")
  [ -n "$val" ]
}

@test "cast_emit_event: event file is valid JSON" {
  cast_emit_event "task_created" "orchestrator" "json-test" "" "" "" ""
  local file
  file=$(ls -1t "$CAST_EVENTS_DIR"/*.json | head -1)
  python3 -c "import json; json.load(open('$file'))"
}

# ---------------------------------------------------------------------------
# 2. cast_write_review
# ---------------------------------------------------------------------------

@test "cast_write_review: creates a file in reviews/ directory" {
  cast_write_review "art-plan-1" "code-reviewer" "approved" "Looks good" ""
  local count
  count=$(ls -1 "$CAST_REVIEWS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "cast_write_review: review file contains correct decision" {
  cast_write_review "art-plan-2" "code-reviewer" "rejected" "Too many issues" ""
  local file
  file=$(ls -1t "$CAST_REVIEWS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "decision")
  [ "$val" = "rejected" ]
}

@test "cast_write_review: review file contains correct reviewer" {
  cast_write_review "art-plan-3" "security" "approved" "No issues found" ""
  local file
  file=$(ls -1t "$CAST_REVIEWS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "reviewer")
  [ "$val" = "security" ]
}

@test "cast_write_review: review file contains correct artifact_id" {
  cast_write_review "my-artifact-id" "code-reviewer" "approved" "ok" ""
  local file
  file=$(ls -1t "$CAST_REVIEWS_DIR"/*.json | head -1)
  local val
  val=$(json_field "$file" "artifact_id")
  [ "$val" = "my-artifact-id" ]
}

@test "cast_write_review: review file is valid JSON" {
  cast_write_review "art-valid" "code-reviewer" "approved" "fine" ""
  local file
  file=$(ls -1t "$CAST_REVIEWS_DIR"/*.json | head -1)
  python3 -c "import json; json.load(open('$file'))"
}

@test "cast_write_review: also emits a review_submitted event" {
  cast_write_review "art-event-check" "code-reviewer" "approved" "ok" ""
  # The function calls cast_emit_event internally — check events/ got a file
  local count
  count=$(ls -1 "$CAST_EVENTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 3. cast_derive_state
# ---------------------------------------------------------------------------

@test "cast_derive_state: creates a state file in state/ directory" {
  cast_emit_event "task_created" "orchestrator" "derive-test-1" "" "Created" "" ""
  cast_derive_state "derive-test-1"
  [ -f "$CAST_STATE_DIR/derive-test-1.json" ]
}

@test "cast_derive_state: state file contains the task_id" {
  cast_emit_event "task_created" "orchestrator" "derive-test-2" "" "Created" "" ""
  cast_derive_state "derive-test-2"
  local val
  val=$(json_field "$CAST_STATE_DIR/derive-test-2.json" "task_id")
  [ "$val" = "derive-test-2" ]
}

@test "cast_derive_state: task_claimed event sets owner and status in_progress" {
  cast_emit_event "task_claimed" "planner" "derive-test-3" "" "Claimed" "" ""
  cast_derive_state "derive-test-3"
  local owner status
  owner=$(json_field "$CAST_STATE_DIR/derive-test-3.json" "owner")
  status=$(json_field "$CAST_STATE_DIR/derive-test-3.json" "status")
  [ "$owner" = "planner" ]
  [ "$status" = "in_progress" ]
}

@test "cast_derive_state: task_blocked event sets status BLOCKED" {
  cast_emit_event "task_blocked" "debugger" "derive-test-4" "" "Blocked" "BLOCKED" ""
  cast_derive_state "derive-test-4"
  local status
  status=$(json_field "$CAST_STATE_DIR/derive-test-4.json" "status")
  [ "$status" = "BLOCKED" ]
}

@test "cast_derive_state: state file is valid JSON" {
  cast_emit_event "task_created" "orchestrator" "derive-json-check" "" "" "" ""
  cast_derive_state "derive-json-check"
  python3 -c "import json; json.load(open('$CAST_STATE_DIR/derive-json-check.json'))"
}

# ---------------------------------------------------------------------------
# 4. Multiple events for same task_id — latest status wins
# ---------------------------------------------------------------------------

@test "multiple events: latest status reflected in derived state" {
  # Emit a sequence: created -> claimed -> completed
  cast_emit_event "task_created"   "orchestrator" "multi-1" "" "Created"   ""     ""
  sleep 1  # ensure timestamps differ so sort order is deterministic
  cast_emit_event "task_claimed"   "planner"      "multi-1" "" "Claimed"   ""     ""
  sleep 1
  cast_emit_event "task_completed" "planner"      "multi-1" "" "Completed" "DONE" ""
  cast_derive_state "multi-1"
  local status
  status=$(json_field "$CAST_STATE_DIR/multi-1.json" "status")
  [ "$status" = "DONE" ]
}

# ---------------------------------------------------------------------------
# 5. cast_check_approvals
# ---------------------------------------------------------------------------

@test "cast_check_approvals: returns 0 when required reviewer has approved" {
  cast_emit_event "task_created" "orchestrator" "approval-task-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "approval-task-1" "plan-1" "" "" ""
  cast_write_review "plan-1" "code-reviewer" "approved" "Looks good" ""
  # Give derive a moment since write_review also emits an event
  cast_derive_state "approval-task-1"
  run cast_check_approvals "approval-task-1" "code-reviewer"
  assert_success
}

@test "cast_check_approvals: returns 1 when required reviewer has not reviewed" {
  cast_emit_event "task_created" "orchestrator" "approval-task-2" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "approval-task-2" "plan-2" "" "" ""
  # No review written
  cast_derive_state "approval-task-2"
  run cast_check_approvals "approval-task-2" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "cast_check_approvals: returns 2 when a rejection is present" {
  cast_emit_event "task_created" "orchestrator" "approval-task-3" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "approval-task-3" "plan-3" "" "" ""
  cast_write_review "plan-3" "code-reviewer" "rejected" "Too many issues" ""
  cast_derive_state "approval-task-3"
  run cast_check_approvals "approval-task-3" "code-reviewer"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 6. cast_read_board smoke test
# ---------------------------------------------------------------------------

@test "cast_read_board: runs without error on empty dirs" {
  run cast_read_board
  assert_success
}

@test "cast_read_board: runs without error when state files exist" {
  cast_emit_event "task_created" "orchestrator" "board-task-1" "" "Test task" "" ""
  cast_derive_state "board-task-1"
  run cast_read_board
  assert_success
}

@test "cast_read_board: output includes task_id when state exists" {
  cast_emit_event "task_created" "orchestrator" "board-visible-task" "" "Visible task" "" ""
  cast_derive_state "board-visible-task"
  run cast_read_board
  assert_output --partial "board-visible-task"
}
