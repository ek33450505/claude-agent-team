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
  # Needed so cast_check_approvals' _record_hatch_ack (external cast_ack.py
  # subprocess) can find cast_ack.py under the temp HOME sandbox — matches
  # the convention already used in cast-ask.bats, cast-review.bats, etc.
  export CAST_SCRIPTS_DIR="$REPO_DIR/scripts"

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
  [ -f "$(_cast_state_file "derive-test-1")" ]
}

@test "cast_derive_state: state file contains the task_id" {
  cast_emit_event "task_created" "orchestrator" "derive-test-2" "" "Created" "" ""
  cast_derive_state "derive-test-2"
  local val
  val=$(json_field "$(_cast_state_file "derive-test-2")" "task_id")
  [ "$val" = "derive-test-2" ]
}

@test "cast_derive_state: task_claimed event sets owner and status in_progress" {
  cast_emit_event "task_claimed" "planner" "derive-test-3" "" "Claimed" "" ""
  cast_derive_state "derive-test-3"
  local sf owner status
  sf="$(_cast_state_file "derive-test-3")"
  owner=$(json_field "$sf" "owner")
  status=$(json_field "$sf" "status")
  [ "$owner" = "planner" ]
  [ "$status" = "in_progress" ]
}

@test "cast_derive_state: task_blocked event sets status BLOCKED" {
  cast_emit_event "task_blocked" "debugger" "derive-test-4" "" "Blocked" "BLOCKED" ""
  cast_derive_state "derive-test-4"
  local status
  status=$(json_field "$(_cast_state_file "derive-test-4")" "status")
  [ "$status" = "BLOCKED" ]
}

@test "cast_derive_state: state file is valid JSON" {
  cast_emit_event "task_created" "orchestrator" "derive-json-check" "" "" "" ""
  cast_derive_state "derive-json-check"
  local sf
  sf="$(_cast_state_file "derive-json-check")"
  python3 -c "import json; json.load(open('$sf'))"
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
  status=$(json_field "$(_cast_state_file "multi-1")" "status")
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

# ---------------------------------------------------------------------------
# 9. cast_derive_state / cast_check_approvals — Tier 1 sticky rejection
#    (v10-sec2 follow-up). Tier 1 (file-based state from cast_derive_state)
#    is resolved BEFORE Tier 2 and short-circuits on `not missing`, so it had
#    the SAME defect Tier 2 was hardened against in section 8: a same-
#    reviewer approval cleared an earlier rejection via an ORDER-INDEPENDENT
#    set difference (`rejections = set(rejections) - set(approvals)`).
#
#    ⚠ Collision note (v10-sec2 follow-up #2): cast_write_review's filename
#    timestamp is second-granularity, so two same-artifact/same-reviewer
#    writes inside one wall-clock second used to collide on the same review
#    file and silently lose one decision — see section 10 below, which tests
#    that failure mode directly (deliberately NO sleep). cast_write_review
#    now makes same-second writes collision-safe unconditionally (a numeric
#    filename suffix on collision), so the `sleep 1` calls in THIS section
#    are no longer needed to avoid data loss — both writes land on disk
#    either way now. They are kept anyway because they are still load-bearing
#    for a DIFFERENT reason: the hatch/newest-wins tests below assert a
#    result that depends on one decision being genuinely chronologically
#    later than the other, which needs real separation in the `timestamp`
#    field itself (still second-granularity) — a same-second tie is, by
#    construction, ambiguous and resolves toward "rejected" instead (see
#    cast_derive_state's sort key). Removing those sleeps would collapse a
#    genuinely-later-approval scenario into an ambiguous tie and flip the
#    expected result. The two default-sticky tests immediately below do NOT
#    actually need their sleep for their own assertion (the sticky path is
#    order-blind by design — see `ever_rejected` in cast_derive_state), but
#    keep it anyway to preserve their named scenario (an explicit
#    "reject-then-approve" / "approve-then-reject" order), distinct from
#    section 10's deliberately-tied case.
# ---------------------------------------------------------------------------

@test "Tier 1 sticky: reject then approve same artifact/reviewer stays rejected (exit 2) — the bug itself" {
  cast_emit_event "task_created" "orchestrator" "tier1-sticky-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-sticky-1" "art-t1-1" "" "" ""
  cast_write_review "art-t1-1" "code-reviewer" "rejected" "Needs fixes" ""
  cast_derive_state "tier1-sticky-1"
  run cast_check_approvals "tier1-sticky-1" "code-reviewer"
  [ "$status" -eq 2 ]

  sleep 1
  cast_write_review "art-t1-1" "code-reviewer" "approved" "Fixed now" ""
  cast_derive_state "tier1-sticky-1"
  run cast_check_approvals "tier1-sticky-1" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "Tier 1 sticky: approval written BEFORE rejection does not clear it (order-independence removed, exit 2)" {
  cast_emit_event "task_created" "orchestrator" "tier1-sticky-2" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-sticky-2" "art-t1-2" "" "" ""
  cast_write_review "art-t1-2" "code-reviewer" "approved" "Looked fine at first" ""
  sleep 1
  cast_write_review "art-t1-2" "code-reviewer" "rejected" "Found an issue on re-read" ""
  cast_derive_state "tier1-sticky-2"
  run cast_check_approvals "tier1-sticky-2" "code-reviewer"
  [ "$status" -eq 2 ]
}

# The next test (approval-after-rejection + hatch -> exit 0) is a regression
# guard, NOT a mutation-safe proof of anything new — mutation-tested
# (2026-08-25): under the pre-fix code this scenario ALREADY returned exit 0
# regardless of the hatch, because pre-fix Tier 1 wasn't hatch-aware at all
# and its order-independent set difference already dropped the rejection
# whenever both decision types existed for a reviewer. Keep it (it locks in
# correct hatch behavior going forward), but the four tests above/below it —
# "the bug itself", "order-independence removed", "does NOT suppress when
# rejection is newest", and "do NOT suppress (literal-1 convention)" — plus
# the ack_events recording test that follows are the ones that actually
# discriminate (all confirmed RED against the pre-fix script, restored GREEN
# after; same mutation-testing shape as section 8's precedent above).
@test "Tier 1 hatch: CAST_REVIEW_BLOCK_OK=1 reverts to newest-decision-wins — approval-after-rejection gives exit 0" {
  cast_emit_event "task_created" "orchestrator" "tier1-hatch-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-hatch-1" "art-t1-3" "" "" ""
  cast_write_review "art-t1-3" "code-reviewer" "rejected" "Needs fixes" ""
  sleep 1
  cast_write_review "art-t1-3" "code-reviewer" "approved" "Fixed now" ""
  cast_derive_state "tier1-hatch-1"
  export CAST_REVIEW_BLOCK_OK=1
  run cast_check_approvals "tier1-hatch-1" "code-reviewer"
  assert_success
}

@test "Tier 1 hatch: CAST_REVIEW_BLOCK_OK=1 does NOT suppress when rejection is the newest decision (exit 2)" {
  cast_emit_event "task_created" "orchestrator" "tier1-hatch-2" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-hatch-2" "art-t1-4" "" "" ""
  cast_write_review "art-t1-4" "code-reviewer" "approved" "Looked fine" ""
  sleep 1
  cast_write_review "art-t1-4" "code-reviewer" "rejected" "Actually found an issue" ""
  cast_derive_state "tier1-hatch-2"
  export CAST_REVIEW_BLOCK_OK=1
  run cast_check_approvals "tier1-hatch-2" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "Tier 1 hatch: CAST_REVIEW_BLOCK_OK=true / =10 do NOT suppress (literal-1 convention, exit 2)" {
  cast_emit_event "task_created" "orchestrator" "tier1-hatch-3" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-hatch-3" "art-t1-5" "" "" ""
  cast_write_review "art-t1-5" "code-reviewer" "rejected" "Needs fixes" ""
  sleep 1
  cast_write_review "art-t1-5" "code-reviewer" "approved" "Fixed now" ""
  cast_derive_state "tier1-hatch-3"

  export CAST_REVIEW_BLOCK_OK=true
  run cast_check_approvals "tier1-hatch-3" "code-reviewer"
  [ "$status" -eq 2 ]

  export CAST_REVIEW_BLOCK_OK=10
  run cast_check_approvals "tier1-hatch-3" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "Tier 1 hatch: CAST_REVIEW_BLOCK_OK=1 bypass is RECORDED in ack_events" {
  _setup_fallback_db
  _assert_ack_events_table_exists

  cast_emit_event "task_created" "orchestrator" "tier1-hatch-4" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "tier1-hatch-4" "art-t1-6" "" "" ""
  cast_write_review "art-t1-6" "code-reviewer" "rejected" "Needs fixes" ""
  sleep 1
  cast_write_review "art-t1-6" "code-reviewer" "approved" "Fixed now" ""
  cast_derive_state "tier1-hatch-4"
  export CAST_REVIEW_BLOCK_OK=1

  local before after
  before=$(_ack_events_count)
  run cast_check_approvals "tier1-hatch-4" "code-reviewer"
  assert_success
  after=$(_ack_events_count)
  [ "$((after - before))" -eq 1 ]

  run _ack_events_latest
  assert_output "CAST_REVIEW_BLOCK_OK|cast-events.sh|0"
}

# ---------------------------------------------------------------------------
# 10. cast_write_review — same-second collision safety (v10-sec2 follow-up
#     #2). Unlike section 9's tests, these deliberately use NO sleep between
#     writes: the whole point is to prove that a rejection immediately
#     followed by a self-approval (realistic at programmatic speed, not just
#     a testing artifact) cannot silently destroy the rejection's evidence.
#     Mutation-tested (2026-08-25) — see completion report for full results.
# ---------------------------------------------------------------------------

@test "collision: reject then immediately approve (no sleep) leaves BOTH review files on disk" {
  cast_emit_event "task_created" "orchestrator" "collision-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "collision-1" "art-c-1" "" "" ""

  # Injected CAST_REVIEW_TS (added in the exclusive-create follow-up, section
  # 12) guarantees both writes compute the SAME candidate path, forcing a
  # real collision deterministically — without it this test could pass "by
  # luck" via two distinct real-clock seconds even when the two writes
  # never actually collided (observed 2026-08-25: see the sibling test
  # below, which genuinely flaked this way before this fix).
  export CAST_REVIEW_TS="20260302T000000Z"
  export CAST_REVIEW_TS_ISO="2026-03-02T00:00:00Z"
  cast_write_review "art-c-1" "code-reviewer" "rejected" "Needs fixes" ""
  cast_write_review "art-c-1" "code-reviewer" "approved" "Fixed now" ""
  unset CAST_REVIEW_TS CAST_REVIEW_TS_ISO

  local count
  count=$(ls -1 "$CAST_REVIEWS_DIR"/art-c-1-code-reviewer-*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]

  cast_derive_state "collision-1"
  run cast_check_approvals "collision-1" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "collision: same-second tie under CAST_REVIEW_BLOCK_OK=1 still rejects — ambiguous tie must not approve" {
  cast_emit_event "task_created" "orchestrator" "collision-2" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "collision-2" "art-c-2" "" "" ""

  # Same determinism fix as the test above, and load-bearing here in a way
  # it wasn't there: under CAST_REVIEW_BLOCK_OK=1 (newest-decision-wins) the
  # exit code genuinely DIFFERS between a true tie (resolves to rejected,
  # exit 2 — what this test asserts) and two distinct real timestamps
  # (the later approval legitimately wins, exit 0) — this test flaked
  # (observed 2026-08-25, real run: exit 0) when two back-to-back
  # `date -u` calls happened to straddle a real second boundary. The
  # injected timestamp removes the wall-clock dependency entirely.
  export CAST_REVIEW_TS="20260302T000000Z"
  export CAST_REVIEW_TS_ISO="2026-03-02T00:00:00Z"
  cast_write_review "art-c-2" "code-reviewer" "rejected" "Needs fixes" ""
  cast_write_review "art-c-2" "code-reviewer" "approved" "Fixed now" ""
  unset CAST_REVIEW_TS CAST_REVIEW_TS_ISO

  local count
  count=$(ls -1 "$CAST_REVIEWS_DIR"/art-c-2-code-reviewer-*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]

  cast_derive_state "collision-2"
  export CAST_REVIEW_BLOCK_OK=1
  run cast_check_approvals "collision-2" "code-reviewer"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 11. cast_emit_event — same-second collision safety (v10-sec2 follow-up
#     #3). Same defect class as section 10, one level up: cast_emit_event's
#     filename is `{ts}-{agent}-{task_id}.json` — no event_type, no
#     artifact_id — so two DIFFERENT-artifact `artifact_written` events for
#     the same agent+task inside one wall-clock second used to collide, and
#     the second silently overwrote the first. Worse than section 10's bug:
#     this needs no self-review or adversarial timing at all — a writer
#     emitting two artifact events back-to-back is a completely normal call
#     pattern. No sleep between emits below — that is the entire point.
#     Mutation-tested (2026-08-25) — see completion report for results.
# ---------------------------------------------------------------------------

@test "collision: two artifact_written events, same agent+task+second, different artifacts — both files exist and artifact_ids has both" {
  cast_emit_event "task_created" "orchestrator" "evt-collision-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "evt-collision-1" "art-e1" "" "" ""
  cast_emit_event "artifact_written" "planner" "evt-collision-1" "art-e2" "" "" ""

  local count
  count=$(ls -1 "$CAST_EVENTS_DIR"/*-planner-evt-collision-1.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]

  cast_derive_state "evt-collision-1"
  local aids
  aids=$(json_field "$(_cast_state_file "evt-collision-1")" "artifact_ids")
  [[ "$aids" == *"art-e1"* ]]
  [[ "$aids" == *"art-e2"* ]]
}

@test "collision: end-to-end bypass — art rejected + a clean sibling artifact, same agent/task/second, gate still rejects (exit 2)" {
  cast_emit_event "artifact_written" "backend-writer" "evt-collision-2" "art-e3" "wrote code" "" ""
  cast_emit_event "artifact_written" "backend-writer" "evt-collision-2" "art-e4" "wrote code" "" ""
  cast_write_review "art-e3" "code-reviewer" "rejected" "real defect" ""
  cast_write_review "art-e4" "code-reviewer" "approved" "lgtm" ""

  cast_derive_state "evt-collision-2"
  run cast_check_approvals "evt-collision-2" "code-reviewer"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 12. Exclusive-create retry — deterministic proof (v10-sec2 follow-up #4).
#     Sections 10/11 proved a SINGLE collision is handled; they don't prove
#     the retry loop itself, and a genuine multi-process race is not
#     something BATS can force deterministically without flaking. Instead of
#     racing real processes, these tests PRE-CREATE the target path and its
#     next few suffix candidates before calling the function, which
#     deterministically forces the exclusive-create retry loop through
#     multiple iterations regardless of wall-clock timing — same technique
#     for the exhaustion tests, just pre-blocking the full bound.
#     cast_write_review previously had no timestamp test seam; added
#     CAST_REVIEW_TS/CAST_REVIEW_TS_ISO here, mirroring the existing
#     CAST_EVENT_TS/CAST_EVENT_TS_ISO seam, so the pre-blocked names can be
#     computed in advance instead of guessed.
#     Mutation-tested (2026-08-25) — see completion report for results.
# ---------------------------------------------------------------------------

@test "retry (write_review): pre-blocked suffixes are skipped deterministically — write lands beyond them, none overwritten" {
  cast_emit_event "task_created" "orchestrator" "retry-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "retry-1" "art-r-1" "" "" ""

  export CAST_REVIEW_TS="20260301T000000Z"
  export CAST_REVIEW_TS_ISO="2026-03-01T00:00:00Z"
  cast_write_review "art-r-1" "code-reviewer" "rejected" "first" ""

  local base="$CAST_REVIEWS_DIR/art-r-1-code-reviewer-20260301T000000Z"
  [ -f "${base}.json" ]

  echo '{"sentinel":"blocker-2"}' >"${base}-2.json"
  echo '{"sentinel":"blocker-3"}' >"${base}-3.json"
  echo '{"sentinel":"blocker-4"}' >"${base}-4.json"

  cast_write_review "art-r-1" "code-reviewer" "approved" "second, after pre-blocked suffixes" ""

  local count
  count=$(ls -1 "${base}"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]

  grep -q "blocker-2" "${base}-2.json"
  grep -q "blocker-3" "${base}-3.json"
  grep -q "blocker-4" "${base}-4.json"
  [ -f "${base}-5.json" ]

  unset CAST_REVIEW_TS CAST_REVIEW_TS_ISO
}

@test "retry (emit_event): pre-blocked suffixes are skipped deterministically — write lands beyond them, none overwritten, both artifacts collected" {
  export CAST_EVENT_TS="20260301T000000Z"
  export CAST_EVENT_TS_ISO="2026-03-01T00:00:00Z"
  cast_emit_event "artifact_written" "planner" "retry-2" "art-r-2" "first" "" ""

  local base="$CAST_EVENTS_DIR/20260301T000000Z"
  [ -f "${base}-planner-retry-2.json" ]

  echo '{"sentinel":"blocker-2"}' >"${base}-2-planner-retry-2.json"
  echo '{"sentinel":"blocker-3"}' >"${base}-3-planner-retry-2.json"
  echo '{"sentinel":"blocker-4"}' >"${base}-4-planner-retry-2.json"

  cast_emit_event "artifact_written" "planner" "retry-2" "art-r-3" "second, after pre-blocked suffixes" "" ""

  local count
  count=$(ls -1 "$CAST_EVENTS_DIR"/20260301T000000Z*-planner-retry-2.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 5 ]

  grep -q "blocker-2" "${base}-2-planner-retry-2.json"
  grep -q "blocker-3" "${base}-3-planner-retry-2.json"
  grep -q "blocker-4" "${base}-4-planner-retry-2.json"
  [ -f "${base}-5-planner-retry-2.json" ]

  cast_derive_state "retry-2"
  local aids
  aids=$(json_field "$(_cast_state_file "retry-2")" "artifact_ids")
  [[ "$aids" == *"art-r-2"* ]]
  [[ "$aids" == *"art-r-3"* ]]

  unset CAST_EVENT_TS CAST_EVENT_TS_ISO
}

@test "retry exhaustion (write_review): fails loudly (nonzero return) instead of silently dropping the review" {
  cast_emit_event "task_created" "orchestrator" "exhaust-1" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "exhaust-1" "art-x-1" "" "" ""

  export CAST_REVIEW_TS="20260301T010000Z"
  export CAST_REVIEW_TS_ISO="2026-03-01T01:00:00Z"

  # Pre-block all 100 candidates the retry loop will ever try (the base
  # name, attempt 0, plus suffixes -2 through -100, attempts 1-99) so every
  # attempt fails — forcing exhaustion deterministically.
  local base="$CAST_REVIEWS_DIR/art-x-1-code-reviewer-20260301T010000Z"
  echo '{}' >"${base}.json"
  local i
  for i in $(seq 2 100); do
    echo '{}' >"${base}-${i}.json"
  done

  run cast_write_review "art-x-1" "code-reviewer" "rejected" "should not be written" ""
  [ "$status" -ne 0 ]
  # Exhaustion must not silently invent a slot outside the documented bound.
  [ ! -f "${base}-101.json" ]

  unset CAST_REVIEW_TS CAST_REVIEW_TS_ISO
}

@test "retry exhaustion (emit_event): fails loudly (nonzero return) instead of silently dropping the event" {
  export CAST_EVENT_TS="20260301T010000Z"
  export CAST_EVENT_TS_ISO="2026-03-01T01:00:00Z"

  mkdir -p "$CAST_EVENTS_DIR"
  local base="$CAST_EVENTS_DIR/20260301T010000Z"
  echo '{}' >"${base}-planner-exhaust-2.json"
  local i
  for i in $(seq 2 100); do
    echo '{}' >"${base}-${i}-planner-exhaust-2.json"
  done

  run cast_emit_event "artifact_written" "planner" "exhaust-2" "art-x-2" "should not be written" "" ""
  [ "$status" -ne 0 ]
  [ ! -f "${base}-101-planner-exhaust-2.json" ]

  unset CAST_EVENT_TS CAST_EVENT_TS_ISO
}

# ---------------------------------------------------------------------------
# 13. Security follow-up (v10-sec2b): C1 reviews-glob artifact scoping, H1
#     task_id path collision, L1 agent/reviewer filename sanitization.
#     C1 — cast_derive_state's reviews glob (`{safe_aid}-*.json`) is a
#     PREFIX match: artifact "art-1"'s review files ALSO satisfy artifact
#     "art"'s glob. Without an exact artifact_id check, a review written
#     for one artifact silently counts (either direction) for any other
#     artifact whose sanitized id is a prefix of the first. Tests 1-2 below
#     are DISCRIMINATING (reverting the `if rv.get("artifact_id") != aid`
#     check turns them red); test 3 is a regression guard, not
#     discriminating on its own (foreign noise plus a genuine same-artifact
#     approval still passes either way — see completion report).
#     H1 — task_id path collision: "a/b" and "a-b" both sanitize to "a-b"
#     via `${task_id//\//-}`, so two different tasks could derive/read the
#     SAME state file. _cast_state_file (shared by writer and reader) now
#     appends a hash of the raw task_id to disambiguate. Test 4 is
#     DISCRIMINATING.
#     L1 — agent/reviewer were interpolated into filenames unsanitized
#     (unlike task_id/artifact_id). Tests 5-6 are DISCRIMINATING: a "/" in
#     either currently causes os.open()'s O_CREAT|O_EXCL to hit an
#     unresolvable subdirectory and crash (uncaught FileNotFoundError),
#     making cast_write_review/cast_emit_event return nonzero.
#     Mutation-tested (2026-08-25) — see completion report for results.
# ---------------------------------------------------------------------------

@test "C1: a review written for a DIFFERENT artifact that happens to prefix-match must NOT satisfy the gate (exit 1, missing) — the bug itself" {
  # Unrelated task writes artifact "art-1" and gets it approved.
  cast_emit_event "artifact_written" "planner" "c1-foreign" "art-1" "" "" ""
  cast_write_review "art-1" "code-reviewer" "approved" "lgtm" ""

  # A DIFFERENT task writes artifact "art" — the foreign review's filename
  # "art-1-code-reviewer-<ts>.json" also matches the glob "art-*.json" that
  # cast_derive_state uses to collect THIS artifact's reviews. No review is
  # ever submitted for "art" itself.
  cast_emit_event "artifact_written" "planner" "c1-victim" "art" "" "" ""

  cast_derive_state "c1-victim"
  run cast_check_approvals "c1-victim" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "C1 inverse: a REJECTION on a different prefix-matching artifact must not spuriously reject either (exit 1, missing, not 2)" {
  cast_emit_event "artifact_written" "planner" "c1-foreign-2" "art-1" "" "" ""
  cast_write_review "art-1" "code-reviewer" "rejected" "unrelated defect" ""

  cast_emit_event "artifact_written" "planner" "c1-victim-2" "art" "" "" ""

  cast_derive_state "c1-victim-2"
  run cast_check_approvals "c1-victim-2" "code-reviewer"
  # Unattributable evidence must not count on EITHER side — missing, not rejected.
  [ "$status" -eq 1 ]
}

@test "C1 positive control: a review genuinely written for the artifact still counts, even with prefix-matching foreign noise present" {
  cast_emit_event "artifact_written" "planner" "c1-foreign-3" "art-1" "" "" ""
  cast_write_review "art-1" "code-reviewer" "approved" "unrelated lgtm" ""

  cast_emit_event "artifact_written" "planner" "c1-victim-3" "art" "" "" ""
  cast_write_review "art" "code-reviewer" "approved" "the real review" ""

  cast_derive_state "c1-victim-3"
  run cast_check_approvals "c1-victim-3" "code-reviewer"
  [ "$status" -eq 0 ]
}

@test "H1: task ids differing only by / vs - do not share derived state (no cross-task rejection bleed)" {
  local task_a="h1-collide-a/b"
  local task_b="h1-collide-a-b"   # naive sanitization of task_a collides exactly here

  cast_emit_event "task_claimed" "planner" "$task_a" "" "" "" ""
  cast_emit_event "artifact_written" "planner" "$task_a" "art-h1a" "" "" ""
  cast_write_review "art-h1a" "code-reviewer" "approved" "task a is clean" ""

  cast_emit_event "task_claimed" "debugger" "$task_b" "" "" "" ""
  cast_emit_event "artifact_written" "debugger" "$task_b" "art-h1b" "" "" ""
  cast_write_review "art-h1b" "code-reviewer" "rejected" "task b has a real defect" ""

  cast_derive_state "$task_a"
  cast_derive_state "$task_b"

  # ⚠ LOAD-BEARING — this path-equality assertion is H1's ONLY real discriminator.
  # The exit-code assertions at the end of this test pass EITHER WAY in a
  # non-concurrent run, because cast_check_approvals re-derives state for its own
  # exact task_id immediately before reading it, which self-heals the collision.
  # Proved by reverting the H1 fix: the test fails HERE, not on the exit codes.
  # Do not "simplify away" as redundant — doing so silently deletes H1's coverage.
  local state_a state_b
  state_a="$(_cast_state_file "$task_a")"
  state_b="$(_cast_state_file "$task_b")"
  [ "$state_a" != "$state_b" ]

  local tid_a tid_b
  tid_a=$(json_field "$state_a" "task_id")
  tid_b=$(json_field "$state_b" "task_id")
  [ "$tid_a" = "$task_a" ]
  [ "$tid_b" = "$task_b" ]

  run cast_check_approvals "$task_a" "code-reviewer"
  [ "$status" -eq 0 ]

  run cast_check_approvals "$task_b" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "L1: reviewer name containing / is sanitized in the filename but preserved raw in the review body" {
  cast_emit_event "artifact_written" "planner" "l1-task" "art-l1" "" "" ""

  run cast_write_review "art-l1" "team/code-reviewer" "approved" "ok" ""
  [ "$status" -eq 0 ]

  local f
  f=$(ls -1 "$CAST_REVIEWS_DIR"/art-l1-team-code-reviewer-*.json 2>/dev/null | head -1)
  [ -n "$f" ]
  [ -f "$f" ]

  local reviewer
  reviewer=$(json_field "$f" "reviewer")
  [ "$reviewer" = "team/code-reviewer" ]
}

@test "L1: agent name containing / is sanitized in the filename but preserved raw in the event body" {
  run cast_emit_event "task_claimed" "team/planner" "l1-task-2" "" "" "" ""
  [ "$status" -eq 0 ]

  local f
  f=$(ls -1 "$CAST_EVENTS_DIR"/*-team-planner-l1-task-2.json 2>/dev/null | head -1)
  [ -n "$f" ]
  [ -f "$f" ]

  local agent
  agent=$(json_field "$f" "agent")
  [ "$agent" = "team/planner" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# SEC-2 defect 6 — the events glob used the RAW task_id while cast_emit_event
# writes filenames with the slash-SANITIZED form, so any task_id containing "/"
# matched zero event files and cast_derive_state silently produced empty state.
# Branch-derived task ids plausibly contain "/" — this branch's own name does.
#
# Standalone because it previously had NO test of its own: it was exercised only
# incidentally, because an unrelated H1 fixture happened to use a task_id with a
# slash in it. Refactoring that fixture would have dropped the coverage with no
# signal at all. This test names the behaviour it guards.
# ──────────────────────────────────────────────────────────────────────────────

@test "defect 6: a task_id containing / still derives state from its events" {
  local tid="feature/v10-slash-task"
  cast_emit_event "artifact_written" "backend-writer" "$tid" "art-slash" "" "" ""

  # The file on disk carries the SANITIZED id; the JSON body carries the raw one.
  run bash -c "ls '$CAST_EVENTS_DIR' | grep -c 'feature-v10-slash-task'"
  assert_output "1"

  cast_derive_state "$tid"
  local state_file
  state_file="$(_cast_state_file "$tid")"
  [ -f "$state_file" ]

  # The artifact must appear in derived state. With the raw-task_id glob this
  # was an empty list, and the state file still existed — which is why the
  # failure was silent rather than loud.
  run bash -c "python3 -c \"import json;print(json.load(open('$state_file'))['artifact_ids'])\""
  assert_output --partial "art-slash"
}

@test "defect 6: a slash task_id does not collect a DIFFERENT task's events" {
  # Sanitizing "a/b" to "a-b" means a literally-named "a-b" task shares the glob.
  # The raw-value exact-match check inside the loop is what keeps them apart, and
  # widening the glob must not have reopened that.
  cast_emit_event "artifact_written" "backend-writer" "sib/one" "art-slashy" "" "" ""
  cast_emit_event "artifact_written" "backend-writer" "sib-one" "art-literal" "" "" ""

  cast_derive_state "sib/one"
  local sf; sf="$(_cast_state_file "sib/one")"
  run bash -c "python3 -c \"import json;print(json.load(open('$sf'))['artifact_ids'])\""
  assert_output --partial "art-slashy"
  refute_output --partial "art-literal"
}
