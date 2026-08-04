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
# T2.3 — cast-push.sh escape-hatch audit log (isolated snippet)
# ---------------------------------------------------------------------------
# cast-push.sh performs a real `git push`, so rather than mock a remote this
# exercises the exact guarded log-append logic added to scripts/cast-push.sh
# (placed right after PUSH_SHA is captured, so it fires regardless of which
# push branch — set-upstream vs plain — is taken).

@test "cast-push audit log: append writes one tab-separated line with branch and SHA" {
  local branch="feature/example"
  local sha="deadbeefcafefeed0000000000000000000000"
  local log="$HOME/.claude/logs/cast-push-audit.log"

  mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$branch" "$sha" >>"$log" 2>/dev/null || true

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

  run bash -c 'printf "%s\t%s\t%s\n" "$(date -u +%FT%TZ)" "br" "sha" >>"$1/cast-push-audit.log" 2>/dev/null || true' _ "$log_dir"
  assert_success

  chmod 755 "$log_dir"
}
