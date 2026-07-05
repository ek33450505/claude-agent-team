#!/usr/bin/env bats
# Tests for the OTLP-feed (otel_events / otel_metrics) index + retention work.
# Covers:
#   (a) cast-db-init.sh provisions all 4 otel indexes on a fresh DB
#   (b) migration 029 backfills the indexes on a legacy DB, is idempotent,
#       and applies cleanly through cast-migrate.py on an empty DB (the
#       CREATE TABLE IF NOT EXISTS guard prevents a "no such table" abort)
#   (c) cast-db-prune.py prunes otel rows older than CAST_PRUNE_OTEL_DAYS
#       while keeping fresh rows, on an independent window from DAYS
#   (d) the otel prune honours the shared fail-closed backup gate
#
# Isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INIT_SCRIPT="$REPO_DIR/scripts/cast-db-init.sh"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.py"
PRUNE_SCRIPT="$REPO_DIR/scripts/cast-db-prune.py"
MIGRATIONS_DIR="$REPO_DIR/scripts/migrations"
OTEL_MIGRATION="$MIGRATIONS_DIR/029_otel_indexes.sql"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude/logs"
  export TEST_DB="$BATS_TEST_TMPDIR/otel-test-$$.db"
  export CAST_DB_PATH="$TEST_DB"
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# Create the otel_events + otel_metrics tables (schema mirrors cast-db-init.sh)
# WITHOUT any indexes — the "legacy DB missing them" fixture.
_create_otel_schema() {
  sqlite3 "$TEST_DB" "
    CREATE TABLE otel_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT,
      event_name TEXT,
      prompt_id TEXT,
      severity TEXT,
      body TEXT,
      time_unix_nano INTEGER,
      received_at TEXT
    );
    CREATE TABLE otel_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT,
      metric_name TEXT NOT NULL,
      value REAL,
      unit TEXT,
      attributes TEXT,
      time_unix_nano INTEGER,
      received_at TEXT
    );
  "
}

_count_otel_indexes() {
  sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN (
    'idx_otel_events_session','idx_otel_events_received',
    'idx_otel_metrics_session','idx_otel_metrics_received');"
}

# ---------------------------------------------------------------------------
# (a) Fresh init provisions all 4 otel indexes
# ---------------------------------------------------------------------------

@test "(a) fresh cast-db-init.sh creates all 4 otel indexes" {
  run bash "$INIT_SCRIPT" --db "$TEST_DB"
  assert_success

  local count
  count=$(_count_otel_indexes)
  [ "$count" -eq 4 ]
}

@test "(a) fresh init: PRAGMA index_list exposes the received_at index on otel_events" {
  run bash "$INIT_SCRIPT" --db "$TEST_DB"
  assert_success

  run sqlite3 "$TEST_DB" "PRAGMA index_list(otel_events);"
  assert_success
  assert_output --partial "idx_otel_events_received"
}

@test "(a) fresh init: PRAGMA index_list exposes the session_id index on otel_metrics" {
  run bash "$INIT_SCRIPT" --db "$TEST_DB"
  assert_success

  run sqlite3 "$TEST_DB" "PRAGMA index_list(otel_metrics);"
  assert_success
  assert_output --partial "idx_otel_metrics_session"
}

# ---------------------------------------------------------------------------
# (b) Migration 029 backfills indexes on a legacy DB + is idempotent
# ---------------------------------------------------------------------------

@test "(b) migration 029 backfills all 4 indexes on a legacy DB missing them" {
  _create_otel_schema
  # Legacy DB starts with zero of the 4 target indexes
  local before
  before=$(_count_otel_indexes)
  [ "$before" -eq 0 ]

  sqlite3 "$TEST_DB" < "$OTEL_MIGRATION"

  local after
  after=$(_count_otel_indexes)
  [ "$after" -eq 4 ]
}

@test "(b) migration 029 is idempotent (second apply is a no-op, no error)" {
  _create_otel_schema

  sqlite3 "$TEST_DB" < "$OTEL_MIGRATION"
  run sqlite3 "$TEST_DB" < "$OTEL_MIGRATION"
  assert_success

  local count
  count=$(_count_otel_indexes)
  [ "$count" -eq 4 ]
}

@test "(b) migration 029 applies through cast-migrate.py on an empty DB (no 'no such table' abort)" {
  # cast-migrate.bats runs the whole migration set against an empty DB. The
  # CREATE TABLE IF NOT EXISTS guard in 029 must let CREATE INDEX succeed even
  # though the otel tables are provisioned only by cast-db-init.sh.
  export CAST_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  mkdir -p "$CAST_BACKUP_DIR"

  run python3 "$MIGRATE_SCRIPT" --confirm
  assert_success

  # 029 must be recorded in the ledger
  local recorded
  recorded=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM schema_migrations WHERE version='029_otel_indexes.sql';")
  [ "$recorded" -eq 1 ]

  # ... and the guard created the tables + all 4 indexes
  local count
  count=$(_count_otel_indexes)
  [ "$count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# (c) Prune removes otel rows older than the window, keeps fresh rows
# ---------------------------------------------------------------------------

@test "(c) prune deletes otel_events older than the OTEL window and keeps fresh rows" {
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-old', datetime('now', '-200 days'));
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-new', datetime('now', '-1 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$PRUNE_SCRIPT"
  assert_success

  local remaining old_count
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  [ "$remaining" -eq 1 ]
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events WHERE session_id='s-old';")
  [ "$old_count" -eq 0 ]

  rm -rf "$backup_dir"
}

@test "(c) prune deletes otel_metrics older than the OTEL window and keeps fresh rows" {
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_metrics (session_id, metric_name, received_at) VALUES ('s-old', 'm', datetime('now', '-200 days'));
    INSERT INTO otel_metrics (session_id, metric_name, received_at) VALUES ('s-new', 'm', datetime('now', '-1 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$PRUNE_SCRIPT"
  assert_success

  local remaining old_count
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_metrics;")
  [ "$remaining" -eq 1 ]
  old_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_metrics WHERE session_id='s-old';")
  [ "$old_count" -eq 0 ]

  rm -rf "$backup_dir"
}

@test "(c) prune honours CAST_PRUNE_OTEL_DAYS override" {
  _create_otel_schema
  # 10 days old — inside the 30-day default window, outside a 7-day override
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-10d', datetime('now', '-10 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"
  export CAST_PRUNE_OTEL_DAYS=7

  run python3 "$PRUNE_SCRIPT"
  assert_success

  local remaining
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  [ "$remaining" -eq 0 ]

  rm -rf "$backup_dir"
}

@test "(c) otel window is independent of CAST_DB_PRUNE_DAYS" {
  # A 45-day-old row: past the 30-day otel window (deleted) but within the
  # 90-day routing/agent_runs window (kept) — proves the windows are separate.
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    CREATE TABLE routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT);
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-45d', datetime('now', '-45 days'));
    INSERT INTO routing_events (timestamp) VALUES (datetime('now', '-45 days'));
  "
  local backup_dir
  backup_dir="$(mktemp -d)"
  export CAST_BACKUP_DIR="$backup_dir"

  run python3 "$PRUNE_SCRIPT"
  assert_success

  local otel_count routing_count
  otel_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  routing_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM routing_events;")
  [ "$otel_count" -eq 0 ]      # 45 > 30 → pruned
  [ "$routing_count" -eq 1 ]   # 45 < 90 → retained

  rm -rf "$backup_dir"
}

# ---------------------------------------------------------------------------
# (d) Fail-closed backup gate protects the otel prune too
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# (e) Floor guard: invalid CAST_PRUNE_OTEL_DAYS aborts with exit 1, no rows deleted
# ---------------------------------------------------------------------------

@test "(e) CAST_PRUNE_OTEL_DAYS=0 aborts exit 1 and leaves rows untouched" {
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-sentinel', datetime('now', '-200 days'));
  "

  run env CAST_PRUNE_OTEL_DAYS=0 python3 "$PRUNE_SCRIPT"
  assert_failure  # must exit 1

  # Sentinel row must NOT have been deleted
  local remaining
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  [ "$remaining" -eq 1 ]
}

@test "(e) CAST_PRUNE_OTEL_DAYS=-7 aborts exit 1 and leaves rows untouched" {
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-sentinel', datetime('now', '-200 days'));
  "

  run env CAST_PRUNE_OTEL_DAYS=-7 python3 "$PRUNE_SCRIPT"
  assert_failure  # must exit 1

  # Sentinel row must NOT have been deleted
  local remaining
  remaining=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  [ "$remaining" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (d) Fail-closed backup gate protects the otel prune too
# ---------------------------------------------------------------------------

@test "(d) fail-closed: backup failure skips the otel prune and keeps rows" {
  _create_otel_schema
  sqlite3 "$TEST_DB" "
    INSERT INTO otel_events (session_id, received_at) VALUES ('s-old', datetime('now', '-200 days'));
    INSERT INTO otel_metrics (session_id, metric_name, received_at) VALUES ('s-old', 'm', datetime('now', '-200 days'));
  "
  # Force backup to fail (root-proof): parent is a regular FILE, so mkdir -p
  # inside it raises NotADirectoryError regardless of uid.
  local blocker
  blocker="$(mktemp -d)/blocker"
  touch "$blocker"
  export CAST_BACKUP_DIR="$blocker/sub"

  run python3 "$PRUNE_SCRIPT"
  assert_success  # must always exit 0 (cron/launchd contract)

  # Old otel rows must NOT have been deleted (fail-closed)
  local ev_count mt_count
  ev_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_events;")
  mt_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM otel_metrics;")
  [ "$ev_count" -eq 1 ]
  [ "$mt_count" -eq 1 ]

  assert_output --partial "ERROR"
}
