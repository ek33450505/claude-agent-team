#!/usr/bin/env bats
# T2.1: CAST_APPROVAL_WINDOW_MIN clamp (1..1440) in cast_check_approvals (scripts/cast-events.sh).
# T2.3: cast-push.sh escape-hatch audit-log append — exercised as an isolated snippet since
#       cast-push.sh performs a real `git push` and is not mockable cheaply here.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_EVENTS_SH="$REPO_DIR/scripts/cast-events.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  # Override all CAST dirs to use the temp home so we never touch ~/.claude
  export CAST_DIR="$HOME/.claude/cast"
  export CAST_EVENTS_DIR="$CAST_DIR/events"
  export CAST_STATE_DIR="$CAST_DIR/state"
  export CAST_REVIEWS_DIR="$CAST_DIR/reviews"
  export CAST_ARTIFACTS_DIR="$CAST_DIR/artifacts"

  # shellcheck source=/dev/null
  source "$CAST_EVENTS_SH"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# T2.1 — window_min clamp (1..1440) in cast_check_approvals's agent_runs fallback
# ---------------------------------------------------------------------------

_setup_fallback_db() {
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  mkdir -p "$(dirname "$CAST_DB_PATH")"
  bash "$REPO_DIR/scripts/cast-db-init.sh" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
}

# Insert an agent_runs row. Args: session_id agent status ended_at_SQL_expr branch
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

@test "window clamp: huge CAST_APPROVAL_WINDOW_MIN is capped to 1440 (printed window=)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_APPROVAL_WINDOW_MIN=999999
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
  assert_output --partial "window=1440m"
}

@test "window clamp: a >24h-stale approval no longer satisfies the gate under a huge window" {
  _setup_fallback_db
  # 2000 minutes (~33.3h) old: inside the raw 999999-minute window, but beyond the
  # clamped 1440-minute (24h) ceiling — proves the clamp actually tightens the gate.
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now','-2000 minutes')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_APPROVAL_WINDOW_MIN=999999
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "window clamp: CAST_APPROVAL_WINDOW_MIN=0 is floored to 1 (printed window=)" {
  _setup_fallback_db
  _insert_run "sess-A" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-A"
  export CAST_APPROVAL_WINDOW_MIN=0
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
  assert_output --partial "window=1m"
}

# ---------------------------------------------------------------------------
# LF-10 — dispatch-naming rule (`<agent>__<label>`) vs the approval gate
# ---------------------------------------------------------------------------
# working-conventions.md requires roster dispatches be named "<agent>__<label>"
# for record attribution. The agent_runs fallback previously matched agent=?
# by exact equality only, so a reviewer dispatched as "code-reviewer__fix-x"
# could never satisfy a "code-reviewer" requirement — the gate reported
# "Missing approvals" even though the review had just run DONE.

@test "dispatch-naming: code-reviewer__label DONE satisfies the code-reviewer gate" {
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewer__fix-advisory" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "dispatch-naming: code-reviewer__label BLOCKED rejects the gate (exit 2)" {
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewer__fix-advisory" "BLOCKED" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "dispatch-naming: bare-prefix name code-reviewer2 does NOT satisfy the gate (anchor proof)" {
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewer2" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "dispatch-naming: 2-char wildcard-position name does NOT satisfy the gate (ESCAPE proof)" {
  # Without ESCAPE, LIKE 'code-reviewer__%' treats each "_" as a single-char
  # wildcard: "XX" satisfies both wildcards and "%" matches the rest, so a
  # naive unescaped pattern would wrongly match "code-reviewerXXfix". The
  # escaped pattern requires a literal "__" substring, which this name lacks.
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewerXXfix" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

@test "dispatch-naming: newest run wins across bare and __-named rows (BLOCKED supersedes DONE)" {
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewer" "DONE" "datetime('now','-2 minutes')" ""
  _insert_run "sess-B" "code-reviewer__fix-advisory" "BLOCKED" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "dispatch-naming: bare code-reviewer DONE still satisfies the gate (regression guard)" {
  _setup_fallback_db
  _insert_run "sess-B" "code-reviewer" "DONE" "datetime('now')" ""
  export CAST_SESSION_ID="sess-B"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "dispatch-naming: no matching row at all still fails closed (exit 1)" {
  _setup_fallback_db
  export CAST_SESSION_ID="sess-empty"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T2.3 — cast-push.sh escape-hatch audit log
# ---------------------------------------------------------------------------
# cast-push.sh performs a real `git push`, so rather than exercise the whole
# script these tests source the extracted cast_push_write_audit_log()
# function (scripts/cast-push-audit-log.sh) directly and call it — the exact
# guarded log-append logic cast-push.sh invokes right after PUSH_SHA is
# captured, so it fires regardless of which push branch — set-upstream vs
# plain — is taken.

@test "cast-push audit log: append writes one tab-separated line with branch and SHA" {
  local branch="feature/example"
  local sha="deadbeefcafefeed0000000000000000000000"
  local log="$HOME/.claude/logs/cast-push-audit.log"

  # shellcheck source=/dev/null
  source "$REPO_DIR/scripts/cast-push-audit-log.sh"
  cast_push_write_audit_log "$branch" "$sha"

  [ -f "$log" ]
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]
  run cat "$log"
  assert_output --partial "$branch"
  assert_output --partial "$sha"
}

@test "cast-push audit log: guarded append never fails even if the log dir is unwritable" {
  local log_dir="$HOME/.claude/logs"
  mkdir -p "$log_dir"
  chmod 000 "$log_dir"

  run bash -c 'source "$1/scripts/cast-push-audit-log.sh" && cast_push_write_audit_log "br" "sha"' _ "$REPO_DIR"
  assert_success

  chmod 755 "$log_dir"
}

# ---------------------------------------------------------------------------
# ISO-timestamp coverage for the agent_runs fallback.
#
# _insert_run seeds ONLY space-format timestamps via datetime('now'), but the
# production hooks write ISO-T/Z (datetime.now(timezone.utc).isoformat()), and
# cast.db timestamp formats are genuinely mixed across tables. Sticky-BLOCKED was
# verified by hand to hold for pure-ISO and for mixed rows, and nothing tested it —
# so a future parse_ts / ORDER BY refactor could break the production format while
# the suite stayed green on a format production never writes.
# ---------------------------------------------------------------------------

_iso_now() { echo "strftime('%Y-%m-%dT%H:%M:%SZ','now')"; }

@test "ISO-T/Z rows: a DONE after a BLOCKED does not clear the rejection" {
  _setup_fallback_db
  _insert_run "sess-ISO" "code-reviewer" "BLOCKED" "strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 minutes')" ""
  _insert_run "sess-ISO" "code-reviewer" "DONE"    "strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minutes')" ""
  export CAST_SESSION_ID="sess-ISO"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "MIXED formats: sticky-BLOCKED still holds when the two rows disagree on format" {
  # The realistic shape: a row written by a bash writer (space format) alongside
  # one written by a python hook (ISO-T/Z). A raw string comparison between the
  # two under- or over-matches depending on direction.
  _setup_fallback_db
  _insert_run "sess-MIX" "code-reviewer" "BLOCKED" "strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 minutes')" ""
  _insert_run "sess-MIX" "code-reviewer" "DONE"    "datetime('now','-1 minutes')" ""
  export CAST_SESSION_ID="sess-MIX"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 2 ]
}

@test "ISO-T/Z rows: a clean DONE still satisfies the gate (the fix is not over-tightened)" {
  _setup_fallback_db
  _insert_run "sess-ISOOK" "code-reviewer" "DONE" "strftime('%Y-%m-%dT%H:%M:%SZ','now')" ""
  export CAST_SESSION_ID="sess-ISOOK"
  run cast_check_approvals "throwaway-task" "code-reviewer"
  assert_success
}

@test "ISO-T/Z rows: the 24h clamp still excludes a stale approval" {
  # Guards the parse path specifically: if an ISO-T/Z ended_at failed to parse and
  # fell back to "no timestamp", a >24h-old row could read as in-window.
  _setup_fallback_db
  _insert_run "sess-ISOOLD" "code-reviewer" "DONE" "strftime('%Y-%m-%dT%H:%M:%SZ','now','-2000 minutes')" ""
  export CAST_SESSION_ID="sess-ISOOLD"
  export CAST_APPROVAL_WINDOW_MIN=999999
  run cast_check_approvals "throwaway-task" "code-reviewer"
  [ "$status" -eq 1 ]
}
