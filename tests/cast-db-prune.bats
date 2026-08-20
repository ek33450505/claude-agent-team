#!/usr/bin/env bats
# Tests for cast-db-prune.py
# Covers: correct column prune, dry-run mode, exit-0 guarantee, missing DB.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-db-prune.py"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$HOME/cast-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Create minimal schema: routing_events(timestamp) + agent_runs(started_at).
  sqlite3 "$TEST_DB" "
    CREATE TABLE routing_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT,
      event_type TEXT,
      data TEXT
    );
    CREATE TABLE agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT,
      started_at TEXT,
      model TEXT,
      status TEXT,
      response TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_input_tokens INTEGER,
      cache_creation_input_tokens INTEGER,
      cost_usd REAL,
      duration_ms INTEGER,
      tool_uses INTEGER
    );
  "

  # Plus agent_runs_daily/mcp_calls_daily so the fail-closed rollup gate
  # (cast-db-rollup.py) can run successfully against this fixture — the
  # rollup requires these tables to exist or it exits 1. Shared helper so
  # this fixture gap (which has now broken two test files) lives in one
  # place — see tests/helpers/setup.bash::seed_rollup_tables. The agent_runs/
  # routing_events tables created above already exist, so the helper's
  # CREATE TABLE IF NOT EXISTS for those is a no-op here.
  seed_rollup_tables "$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# --- exit-0 guarantee ---

@test "exits 0 when DB does not exist" {
  export CAST_DB_PATH="/nonexistent/path/no-cast.db"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 on normal run with empty tables" {
  run python3 "$SCRIPT"
  assert_success
}

# --- routing_events prune (correct column: timestamp) ---

@test "deletes old routing_events row and keeps recent one" {
  # Old row: 200 days ago (well beyond 90-day default)
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-1 days'));
  "
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$remaining" -eq 1 ]
  # The remaining row should be the recent one
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events WHERE timestamp < datetime('now', '-90 days');")
  [ "$old_count" -eq 0 ]
}

# --- agent_runs prune (column: started_at) ---

@test "deletes old agent_runs row and keeps recent one" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-1 days'));
  "
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$remaining" -eq 1 ]
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs WHERE started_at < datetime('now', '-90 days');")
  [ "$old_count" -eq 0 ]
}

# --- dry-run mode ---

@test "dry-run preserves old rows but reports would-delete count" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success

  # Rows must still exist after dry-run
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  # Output must mention "would delete" counts
  assert_output --partial "would delete"
}

@test "dry-run reports 0 for tables with no old rows" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-1 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-1 days'));
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "would delete 0 row(s)"
}

# --- tolerance: missing table or column should not abort other step ---

@test "exits 0 even if routing_events table is missing" {
  sqlite3 "$TEST_DB" "DROP TABLE routing_events;"
  run python3 "$SCRIPT"
  assert_success
}

@test "exits 0 even if agent_runs table is missing" {
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs;"
  run python3 "$SCRIPT"
  assert_success
}

# --- configurable retention ---

@test "respects CAST_DB_PRUNE_DAYS override" {
  # Insert a row 10 days old — within default 90-day window but outside 7-day window
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-10 days'));
  "
  export CAST_DB_PRUNE_DAYS=7
  run python3 "$SCRIPT"
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$remaining" -eq 0 ]
}

# --- fail-closed backup gate ---

@test "real prune: backup artifact created before rows are deleted" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success

  # Backup artifact must exist
  local backup_count
  backup_count=$(ls "$backup_dir"/cast-db-*.db 2>/dev/null | wc -l | tr -d ' ')
  [ "$backup_count" -ge 1 ]

  # Old rows must have been deleted
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 0 ]
  [ "$ar_count" -eq 0 ]

  rm -rf "$backup_dir"
}

@test "fail-closed: backup failure skips prune and exits 0" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  # Force backup to fail: parent is a regular FILE, so mkdir -p inside it raises
  # NotADirectoryError for everyone — including root (root-proof).
  local blocker
  blocker="$(mktemp -d)/blocker"
  touch "$blocker"
  export CAST_BACKUP_DIR="$blocker/sub"

  run python3 "$SCRIPT"
  assert_success  # must always exit 0 (cron/launchd contract)

  # Rows must NOT have been deleted (fail-closed)
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  # Output must mention ERROR
  assert_output --partial "ERROR"
}

# --- CLI argument parsing (argparse) ---
# A stray/unknown flag must NEVER fall through and run the prune (2026-07-05 footgun).

@test "--help exits 0 WITHOUT pruning (no backup, no deletion)" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT" --help
  assert_success
  assert_output --partial "usage:"

  # No backup artifact created (backup runs only on a real prune path)
  local backup_count
  backup_count=$(ls "$backup_dir"/cast-db-*.db 2>/dev/null | wc -l | tr -d ' ')
  [ "$backup_count" -eq 0 ]

  # Old rows untouched (nothing was pruned)
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "unknown flag exits 2 WITHOUT pruning" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  run python3 "$SCRIPT" --bogus-flag
  [ "$status" -eq 2 ]

  # Old rows untouched — a typo must never reach the delete path
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]
}

@test "--dry-run flag deletes nothing and reports would-delete" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  run python3 "$SCRIPT" --dry-run
  assert_success
  assert_output --partial "would delete"

  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]
}

@test "--days flag overrides retention window" {
  # 10-day-old row: kept by default 90, pruned by --days 7
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-10 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT" --days 7
  assert_success
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$remaining" -eq 0 ]

  rm -rf "$backup_dir"
}

# --- VACUUM (page reclaim after real deletes) ---

@test "VACUUM runs and logs completion after a real delete" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "VACUUM complete"

  rm -rf "$backup_dir"
}

@test "VACUUM is skipped when no rows were deleted" {
  # Real (non-dry-run) prune with no old rows present — nothing to reclaim.
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success
  assert_output --partial "VACUUM skipped — no rows deleted this run"
  refute_output --partial "VACUUM complete"

  rm -rf "$backup_dir"
}

@test "VACUUM does not run in dry-run mode" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success
  refute_output --partial "VACUUM complete"
  refute_output --partial "VACUUM skipped"
}

@test "dry-run does not invoke backup and deletes nothing" {
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-200 days'));
    INSERT INTO agent_runs (agent, started_at) VALUES ('bot', datetime('now', '-200 days'));
  "
  # Force backup to fail (root-proof): parent is a regular FILE so mkdir -p
  # raises NotADirectoryError regardless of uid.  Correct dry-run behaviour
  # skips the gate entirely, so the script must still exit 0 here.
  local blocker
  blocker="$(mktemp -d)/blocker"
  touch "$blocker"
  export CAST_BACKUP_DIR="$blocker/sub"
  export CAST_DB_PRUNE_DRY_RUN=1

  run python3 "$SCRIPT"
  assert_success

  # Rows must still exist (dry-run never deletes)
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  # Output must mention "would delete" (dry-run reporting)
  assert_output --partial "would delete"
}

# --- fail-closed rollup gate (C5 unit 2) ---
# cast-db-rollup.py runs as a SECOND fail-closed pre-delete gate, after the
# backup gate and before any DELETE. See scripts/cast-db-rollup.py contract:
# rc 0 + one-line JSON on stdout on success; rc 1 + empty stdout, error on
# stderr on failure (missing/empty rollup tables, SQL error, etc).

@test "real prune: rollup runs before deletes and populates agent_runs_daily" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('backend-writer', datetime('now', '-1 days'), 'done');
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success

  local daily_count
  daily_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs_daily;")
  [ "$daily_count" -ge 1 ]

  rm -rf "$backup_dir"
}

@test "real prune: an OLD row is rolled up BEFORE it is deleted (trend survives the prune)" {
  # T1 above seeds a -1 days row, which is NEVER pruned at the 90-day default
  # — it cannot distinguish gate-runs-before-deletes from gate-runs-after.
  # This test seeds an OLD row (pruned at the default window) and asserts
  # BOTH that the raw row is gone AND that its cost/count survived into the
  # aggregate — the only way that can happen is rollup-before-delete.
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, model, status, cost_usd)
    VALUES ('old-agent', datetime('now', '-200 days'), 'opus', 'DONE', 4.25);
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success

  local raw_count daily_count
  raw_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  daily_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs_daily;")
  [ "$raw_count" -eq 0 ]
  [ "$daily_count" -eq 1 ]

  local runs cost_usd
  runs=$(sqlite3 "$TEST_DB" "SELECT runs FROM agent_runs_daily WHERE agent='old-agent';")
  cost_usd=$(sqlite3 "$TEST_DB" "SELECT cost_usd FROM agent_runs_daily WHERE agent='old-agent';")
  [ "$runs" -eq 1 ]
  [ "$cost_usd" = "4.25" ]

  rm -rf "$backup_dir"
}

@test "fail-closed: rollup failure skips ALL deletes and exits 0" {
  # Make the rollup fail WITHOUT making the backup fail: drop one of its
  # required tables (measured: rollup exits 1 with "does not exist").
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs_daily;"
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp, event_type, data) VALUES (datetime('now', '-200 days'), 'x', '{}');
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success  # launchd contract preserved even on fail-closed skip

  # The assertion that actually proves fail-closed: the OLD rows must still
  # be present — deletes were skipped, not just logged as skipped.
  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]

  # Output must name the failure loudly.
  assert_output --partial "ERROR"
  assert_output --partial "rollup"

  rm -rf "$backup_dir"
}

@test "fail-closed: rollup failure also skips the OTLP delete steps" {
  # Same rollup-failure trigger as above, but this pins Ed's explicit
  # decision that the gate blocks EVERYTHING, including otel_events/
  # otel_metrics — tables that nothing rolls up.
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs_daily;"
  sqlite3 "$TEST_DB" "
    CREATE TABLE otel_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT,
      received_at TEXT
    );
    CREATE TABLE otel_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT,
      metric_name TEXT,
      received_at TEXT
    );
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-old', datetime('now', '-200 days'));
    INSERT INTO otel_metrics (session_id, metric_name, received_at) VALUES ('s-old', 'm', datetime('now', '-200 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$SCRIPT"
  assert_success

  events_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  metrics_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_metrics;")
  [ "$events_count" -eq 1 ]
  [ "$metrics_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "dry-run does not invoke the rollup" {
  # DROP a required rollup table so an invocation would fail loudly; if
  # dry-run wrongly invoked the rollup, this test would see the ERROR text.
  sqlite3 "$TEST_DB" "DROP TABLE agent_runs_daily;"
  sqlite3 "$TEST_DB" "
    INSERT INTO routing_events (timestamp, event_type, data) VALUES (datetime('now', '-200 days'), 'x', '{}');
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  export CAST_DB_PRUNE_DRY_RUN=1
  run python3 "$SCRIPT"
  assert_success
  refute_output --partial "rollup"

  re_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$re_count" -eq 1 ]
  [ "$ar_count" -eq 1 ]
}

@test "rollup receives the prune's --days override, not the env default" {
  # Behavioral discriminator: build a shadow scripts dir with the REAL
  # cast-db-prune.py + cast-db-backup.py (both stdlib-only, no cross-repo
  # imports) but a STUB cast-db-rollup.py that records its own argv instead
  # of rolling anything up. This proves the exact --authoritative-days value
  # cast-db-prune.py's shipped code passes through, rather than inferring it
  # indirectly from rollup's internal authoritative/insert-only SQL split
  # (out of budget to construct with confidence — see Concerns).
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"

  local argv_capture="$BATS_TEST_TMPDIR/rollup-argv.txt"
  cat > "$shadow_dir/cast-db-rollup.py" <<STUB
#!/usr/bin/env python3
import sys, json
with open("$argv_capture", "w") as f:
    f.write(" ".join(sys.argv[1:]))
print(json.dumps({"agent_runs_daily": 0, "mcp_calls_daily": 0, "excluded_agent_runs": 0, "excluded_mcp_calls": 0, "dry_run": False}))
sys.exit(0)
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py" --days 30
  assert_success

  local captured
  captured="$(cat "$argv_capture")"
  [[ "$captured" == *"--authoritative-days 30"* ]]
  [[ "$captured" != *"--authoritative-days 90"* ]]

  rm -rf "$backup_dir"
}

# --- LAYER 2 validation: exit 0 alone is not proof the rollup wrote anything ---
# Each test seeds an OLD (200-day) agent_runs row and asserts it SURVIVES —
# the surviving row is the real proof the deletes were skipped, not log text.

@test "rollup gate rejects exit-0-with-no-stdout (unparseable) and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-a"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
import sys
sys.exit(0)
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success
  assert_output --partial "unparseable"

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "rollup gate rejects exit-0-with-empty-dict payload and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-b"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
print("{}")
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "rollup gate rejects exit-0 dry_run:true payload and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-c"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
print('{"agent_runs_daily":0,"mcp_calls_daily":0,"excluded_agent_runs":0,"excluded_mcp_calls":0,"dry_run":true}')
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "env-scrub regression: CAST_DB_ROLLUP_DRY_RUN=1 in the caller's env does not leak into the real rollup child" {
  # THE CASE-D REGRESSION TEST. No stub — the REAL scripts/cast-db-rollup.py.
  # Pre-fix: the child inherited CAST_DB_ROLLUP_DRY_RUN=1 from this process's
  # environment, ran in dry-run, wrote nothing, and exited 0 — the aggregate
  # was silently never written (daily=0) while the raw row was still pruned
  # (raw=0), permanently losing the cost/trend data. Post-fix: the gate's own
  # child_env scrub forces the child to run for real regardless of the
  # caller's ambient env, so the aggregate IS written before the raw row is
  # deleted.
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, model, status, cost_usd)
    VALUES ('old-agent', datetime('now', '-200 days'), 'opus', 'DONE', 4.25);
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"
  export CAST_DB_ROLLUP_DRY_RUN=1

  run python3 "$SCRIPT"
  assert_success

  local ar_count daily_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  daily_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs_daily;")
  [ "$ar_count" -eq 0 ]
  [ "$daily_count" -eq 1 ]

  rm -rf "$backup_dir"
}

# --- log-injection security regression ---
# _pre_prune_rollup() (and _pre_prune_backup()) used to interpolate
# error_detail into _log() WITHOUT repr(), so embedded newlines from the
# child's stdout/stderr landed in the log as extra lines with NO [timestamp]
# prefix -- visually indistinguishable from genuine log entries. Fixed by
# interpolating {error_detail!r} at both call sites.

@test "log injection: multi-line child stderr cannot inject unprefixed log lines" {
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-inject"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
import sys
sys.stderr.write("[2026-01-01T00:00:00Z] cast-db-rollup starting -- db=fake\n")
sys.stderr.write("ERROR: unexpected failure: no such table: routing_events\n")
sys.exit(1)
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success

  local log_file
  log_file="$HOME/.claude/logs/cron-db-prune.log"
  [ -f "$log_file" ]

  # Every non-blank line in the run's log file must begin with a "["
  # timestamp -- i.e. the child's embedded newlines were escaped (as \n
  # inside a repr()'d string), never passed through as raw line breaks.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \[* ]] || { echo "unprefixed log line found: $line" >&2; return 1; }
  done < "$log_file"

  rm -rf "$backup_dir"
}

# --- LAYER 2 count-validation coverage ---
# Each test drives execution PAST the JSON-parse check, the non-dict check,
# and the dry_run check (payload has dry_run:false and all four keys
# present-or-not per case) so the four-key count-validation loop itself is
# reached. Each seeds a 200-day-old agent_runs row and asserts it SURVIVES --
# the surviving row is the proof, not log text.

@test "count validation: negative agent_runs_daily rejects rollup payload and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-neg"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
print('{"agent_runs_daily":-1,"mcp_calls_daily":0,"excluded_agent_runs":0,"excluded_mcp_calls":0,"dry_run":false}')
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "count validation: bool agent_runs_daily (isinstance(True,int) trap) rejects rollup payload and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-bool"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
print('{"agent_runs_daily":true,"mcp_calls_daily":0,"excluded_agent_runs":0,"excluded_mcp_calls":0,"dry_run":false}')
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success
  assert_output --partial "agent_runs_daily=True"

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}

@test "count validation: missing agent_runs_daily key rejects rollup payload and skips deletes" {
  sqlite3 "$TEST_DB" "
    INSERT INTO agent_runs (agent, started_at, status) VALUES ('bot', datetime('now', '-200 days'), 'done');
  "
  local shadow_dir
  shadow_dir="$BATS_TEST_TMPDIR/shadow-scripts-missing"
  mkdir -p "$shadow_dir"
  cp "$SCRIPT" "$shadow_dir/cast-db-prune.py"
  cp "$REPO_DIR/scripts/cast-db-backup.py" "$shadow_dir/cast-db-backup.py"
  cat > "$shadow_dir/cast-db-rollup.py" <<'STUB'
#!/usr/bin/env python3
print('{"mcp_calls_daily":0,"excluded_agent_runs":0,"excluded_mcp_calls":0,"dry_run":false}')
STUB
  chmod +x "$shadow_dir/cast-db-rollup.py"

  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$shadow_dir/cast-db-prune.py"
  assert_success
  assert_output --partial "agent_runs_daily=None"

  local ar_count
  ar_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_runs;")
  [ "$ar_count" -eq 1 ]

  rm -rf "$backup_dir"
}
