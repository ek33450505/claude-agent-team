#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_EVENTS_SH="$REPO_DIR/scripts/cast-events.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

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
  teardown_temp_home
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
  # Injected timestamps ensure strictly-increasing filename sort order without sleep
  CAST_EVENT_TS="20260101T000001Z" CAST_EVENT_TS_ISO="2026-01-01T00:00:01Z" \
    cast_emit_event "task_created"   "orchestrator" "multi-1" "" "Created"   ""     ""
  CAST_EVENT_TS="20260101T000002Z" CAST_EVENT_TS_ISO="2026-01-01T00:00:02Z" \
    cast_emit_event "task_claimed"   "planner"      "multi-1" "" "Claimed"   ""     ""
  CAST_EVENT_TS="20260101T000003Z" CAST_EVENT_TS_ISO="2026-01-01T00:00:03Z" \
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

# ---------------------------------------------------------------------------
# 7. cast_check_approvals — session-scoped agent_runs fallback (Root Cause 4)
# ---------------------------------------------------------------------------
# Exercises the fallback that lets an ad-hoc Agent-tool dispatch's hook-populated
# agent_runs row satisfy the commit gate when no file-based review record exists.
# See docs/phase14-review-plumbing.md (Root Cause 4).

# Build an isolated cast.db with an agent_runs table inside the temp HOME.
_setup_fallback_db() {
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  mkdir -p "$(dirname "$CAST_DB_PATH")"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
}

# Insert an agent_runs row. Args: session_id agent status ended_at_SQL_expr branch
# Uses a parameterized sqlite3 INSERT (via python3) rather than shell-interpolated SQL,
# matching the production query pattern in cast_check_approvals (code-reviewer finding).
_insert_run() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$CAST_DB_PATH" <<'PYEOF'
import sqlite3, sys
session_id, agent, status, ended_at_expr, branch, db_path = sys.argv[1:]
conn = sqlite3.connect(db_path, timeout=5)
try:
    ended_at = conn.execute(f"SELECT {ended_at_expr}").fetchone()[0]
    conn.execute(
        "INSERT INTO agent_runs (session_id, agent, status, started_at, ended_at, branch) "
        "VALUES (?, ?, ?, datetime('now','-2 minutes'), ?, ?)",
        (session_id, agent, status, ended_at, branch),
    )
    conn.commit()
finally:
    conn.close()
PYEOF
}

@test "fallback: session code-reviewer DONE (blank branch) approves (exit 0)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "fallback: session code-reviewer BLOCKED rejects (exit 2)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "fallback: review in a DIFFERENT session is missing (exit 1)" {
  _setup_fallback_db
  _insert_run "sess-OTHER" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "fallback: review older than the window is missing (exit 1)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now','-5 hours')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_APPROVAL_WINDOW_MIN=120
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "fallback: branch mismatch is missing (exit 1)" {
  _setup_fallback_db
  cd "$REPO_DIR"
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" "definitely-not-current-branch-xyz"
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "fallback: branch match approves (exit 0)" {
  _setup_fallback_db
  cd "$REPO_DIR"
  local cur; cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" "$cur"
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "fallback: no session id fails closed, missing (exit 1)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  unset CAST_SESSION_ID
  unset CLAUDE_SESSION_ID
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 8. cast_check_approvals — sticky BLOCKED (Tier 2 fallback: a later DONE can
#    never silently supersede an earlier BLOCKED). This is DELIBERATELY
#    STRICTER than Tier 1's order-independent set-difference resolution
#    (`rejections - approvals`, where a same-reviewer approval clears an
#    earlier rejection) — Tier 2 never clears a BLOCKED via a later approval,
#    because a self-dispatched `code-reviewer__<label>` shares the enclosing
#    session_id and would otherwise silently overturn an orchestrator's
#    rejection. See v10-sec2 dispatch.
# ---------------------------------------------------------------------------

@test "sticky: earlier BLOCKED + later DONE rejects (exit 2) — the bug itself" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "sticky: earlier BLOCKED + later __label DONE rejects (exit 2) — real-world self-review shape" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer__self" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

# The next three tests (freshness-window, branch-guard, CAST_REVIEW_BLOCK_OK=1)
# are regression guards, not mutation-safe proofs of the sticky-BLOCKED fix —
# each fixture's *newest* row is already DONE, so pre-fix most-recent-wins
# resolution would pass them too. Keep them (they lock in real behavior), but
# don't mistake a pass here for evidence the fix is doing anything; the two
# "bug itself" tests above and the literal-1-convention test below are the
# ones that actually discriminate (code-reviewer finding).
@test "sticky: BLOCKED outside the freshness window does not stick; fresh DONE approves (exit 0)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-5 hours')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_APPROVAL_WINDOW_MIN=120
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "sticky: BLOCKED on a different branch does not stick when the branch guard applies (exit 0)" {
  _setup_fallback_db
  cd "$REPO_DIR"
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" "definitely-not-current-branch-xyz"
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "sticky: CAST_REVIEW_BLOCK_OK=1 suppresses the sticky block (exit 0)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_REVIEW_BLOCK_OK=1
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

# ---------------------------------------------------------------------------
# 8a. The hatch must RECORD the bypass, not just permit it. `exit 0` alone
#     cannot distinguish "hatch recorded the bypass" from "hatch silently
#     dropped the record" — assert the ack_events row directly.
# ---------------------------------------------------------------------------

# Guard against a vacuous pass: confirm ack_events actually exists before any
# test below counts rows in it, so "0 before, 0 after" can't be mistaken for
# "the hatch recorded nothing" when the real cause is a missing table.
_assert_ack_events_table_exists() {
  local exists
  exists=$(python3 - "$CAST_DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1], timeout=5)
try:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='ack_events'"
    ).fetchone()
    print(1 if row else 0)
finally:
    conn.close()
PYEOF
)
  [ "$exists" = "1" ]
}

_ack_events_count() {
  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1], timeout=5)
try:
    print(conn.execute("SELECT COUNT(*) FROM ack_events").fetchone()[0])
finally:
    conn.close()
PYEOF
}

# Newest ack_events row as "variable|script|has_reason", or "NONE" if empty.
_ack_events_latest() {
  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1], timeout=5)
try:
    row = conn.execute(
        "SELECT variable, script, has_reason FROM ack_events ORDER BY id DESC LIMIT 1"
    ).fetchone()
    print("|".join(str(x) for x in row) if row else "NONE")
finally:
    conn.close()
PYEOF
}

@test "sticky: CAST_REVIEW_BLOCK_OK=1 is RECORDED in ack_events, not just permitted" {
  _setup_fallback_db
  _assert_ack_events_table_exists

  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_REVIEW_BLOCK_OK=1

  local before after
  before=$(_ack_events_count)
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
  after=$(_ack_events_count)
  [ "$((after - before))" -eq 1 ]

  run _ack_events_latest
  assert_output "CAST_REVIEW_BLOCK_OK|cast-events.sh|0"
}

@test "sticky: WITHOUT the hatch, no bypass row is added to ack_events (control)" {
  _setup_fallback_db
  _assert_ack_events_table_exists

  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  unset CAST_REVIEW_BLOCK_OK

  local before after
  before=$(_ack_events_count)
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
  after=$(_ack_events_count)
  [ "$after" -eq "$before" ]
}

@test "sticky: CAST_REVIEW_BLOCK_OK=true / =10 do NOT suppress the block (literal-1 convention, exit 2)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "BLOCKED" "datetime('now','-10 minutes')" ""
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"

  export CAST_REVIEW_BLOCK_OK=true
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]

  export CAST_REVIEW_BLOCK_OK=10
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}
