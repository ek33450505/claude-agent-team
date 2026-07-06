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

  # Create minimal schema: routing_events(timestamp) + agent_runs(started_at)
  sqlite3 "$TEST_DB" "
    CREATE TABLE routing_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT
    );
    CREATE TABLE agent_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT,
      started_at TEXT
    );
  "
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
