#!/usr/bin/env bats
# tests/cast-doctor-backup-fresh.bats — doctor "18. Backup freshness" on a fresh install
#
# On a brand-new install no backup snapshot exists yet, which must be INFO (not a
# WARN that flips doctor's rc to 1) -- but ONLY while cast.db is younger than the
# backup threshold. An older DB with no snapshot (stopped backup job) must still
# WARN. The same predicate downgrades Litestream's "replica dir empty" line.
#
# cast.db age = the OLDER of filesystem birth time (macOS) and
# every schema_migrations.applied_at row; the older source wins, so a faked birth
# time can only make the DB look older. Old-DB cases age the DB via the ledger.
#
# Isolation: ALL tests use setup_temp_home/teardown_temp_home -- never real $HOME.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="${REPO_DIR}/bin/cast"

_create_minimal_db() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT, model TEXT, project_dir TEXT, session_type TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0.0, duration_ms INTEGER, tool_uses INTEGER DEFAULT 0, outcome TEXT);
CREATE TABLE IF NOT EXISTS agent_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, started_at TEXT, ended_at TEXT, status TEXT, duration_ms INTEGER, tool_uses INTEGER, outcome TEXT);
CREATE TABLE IF NOT EXISTS routing_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, matched_route TEXT, event_type TEXT, data TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, confidence REAL DEFAULT 1.0, last_validated_at TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS tool_call_failures (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, tool_name TEXT, error TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS agent_truncations (id TEXT PRIMARY KEY, session_id TEXT, agent_name TEXT, truncated_at TEXT, severity TEXT, snippet TEXT);
CREATE TABLE IF NOT EXISTS injection_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, injected_at TEXT, source TEXT, content_preview TEXT);
CREATE TABLE IF NOT EXISTS quality_gates (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, gate_name TEXT, result TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS dispatch_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent_name TEXT, reason TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS task_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT, agent TEXT, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS routines (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, agent TEXT, schedule TEXT, status TEXT, last_run TEXT);
CREATE TABLE IF NOT EXISTS incidents (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, severity TEXT, description TEXT, timestamp TEXT);
CREATE TABLE IF NOT EXISTS plan_sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, plan_file TEXT, status TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE IF NOT EXISTS memory_consolidation_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ran_at TEXT, merged_count INTEGER, pruned_count INTEGER);
CREATE TABLE IF NOT EXISTS archived_memories (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT, key TEXT, value TEXT, archived_at TEXT);
CREATE TABLE IF NOT EXISTS budgets (id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT, budget_usd REAL, spent_usd REAL, updated_at TEXT);
CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT (datetime('now')), checksum TEXT);
SQL
}

setup() {
  load 'helpers/setup'
  setup_temp_home

  mkdir -p "$HOME/.claude"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  _create_minimal_db "$CAST_DB_PATH"

  # Backups and Litestream roots live inside the temp HOME; no snapshot exists.
  export CAST_BACKUP_ROOT="${HOME}/backups-test"
  export CAST_LITESTREAM_ROOT="${HOME}/Library/Application Support/cast-litestream-test"
  export CAST_AGENTS_DIR="${REPO_DIR}/agents/core"
  export CLAUDE_SUBPROCESS=0

  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  mkdir -p "$FAKE_BIN"
  # No-op GUI/launchd shims (same surfaces as cast-doctor-litestream.bats)
  local b
  for b in launchctl osascript notify-send terminal-notifier open; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/${b}"
    chmod +x "${FAKE_BIN}/${b}"
  done
}

teardown() {
  teardown_temp_home
}

_run_doctor() {
  run env -u CAST_BACKUP_MAX_AGE_HOURS PATH="${FAKE_BIN}:${PATH}" \
    HOME="$HOME" \
    CAST_DB_PATH="$CAST_DB_PATH" \
    CAST_BACKUP_ROOT="$CAST_BACKUP_ROOT" \
    CAST_LITESTREAM_ROOT="$CAST_LITESTREAM_ROOT" \
    CAST_AGENTS_DIR="$CAST_AGENTS_DIR" \
    ${EXTRA_ENV:-} \
    CLAUDE_SUBPROCESS=0 \
    bash "$CAST_BIN" doctor 2>&1
}

_migration_applied() { # <sqlite datetime modifier>
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('1', datetime('now'$([ "$1" = now ] || printf ",'%s'" "$1")));"
}

_enable_litestream() {
  printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/litestream"
  chmod +x "${FAKE_BIN}/litestream"
  mkdir -p "${CAST_LITESTREAM_ROOT}/litestream/cast-db"
  printf 'dbs:\n  - path: %s\n' "$CAST_DB_PATH" > "${CAST_LITESTREAM_ROOT}/litestream.yml"
}

_backup_line() { printf '%s\n' "$output" | grep 'Backups:' || true; }
_ls_line() { printf '%s\n' "$output" | grep 'Litestream: replica' || true; }

_platform_has_birthtime() {
  python3 -I -c 'import os,sys; sys.exit(0 if hasattr(os.stat("."), "st_birthtime") else 1)'
}

@test "fresh install: no snapshot + young DB prints INFO 'no snapshot yet (new install ...)', not the WARN" {
  _migration_applied 'now'

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet (new install: cast.db is "* ]]
  [[ "$line" == *"— run: cast backup"* ]]
  [[ "$line" != *"no snapshot found"* ]]
  [[ "$line" != *"!!"* ]]
  [[ "$line" == *"--"* ]]
}

@test "fresh install with no schema_migrations rows: birth time alone proves freshness (macOS)" {
  _platform_has_birthtime || skip "no st_birthtime on this platform; covered by the schema_migrations case"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet"* ]]
  [[ "$line" == *"--"* ]]
  [[ "$line" != *"!!"* ]]
}

@test "old DB (schema_migrations 10 days ago) + no snapshot still WARNs and fails doctor" {
  _migration_applied '-10 days'

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" == *"!!"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
  assert_output --partial "Some checks need attention"
  [ "$status" -ne 0 ]
}

@test "old migrations ledger beats a young birth time (older age source wins)" {
  # Same shape as the old-DB case, named for the property: a restored/copied DB
  # has a young birth time but an old ledger and must NOT read as fresh.
  _migration_applied '-3 days'

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"no snapshot found"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "fresh DB but threshold 0h: not fresh, WARN (stricter threshold never goes quieter)" {
  _migration_applied 'now'

  EXTRA_ENV="CAST_BACKUP_MAX_AGE_HOURS=0" _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"no snapshot found"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "undeterminable age (empty ledger, no birth time) fails loud with the WARN" {
  _platform_has_birthtime && skip "platform has st_birthtime (macOS); age is always determinable here"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"no snapshot found"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "fresh install: an existing snapshot takes the normal path, not the fresh INFO" {
  _migration_applied 'now'
  mkdir -p "${CAST_BACKUP_ROOT}/cast-snapshot-test"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: snapshot cast-snapshot-test"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
}

@test "Litestream empty replica dir: INFO while fresh" {
  _migration_applied 'now'
  _enable_litestream

  _run_doctor
  line="$(_ls_line)"
  [[ "$line" == *"Litestream: replica dir empty (new install: cast.db is "* ]]
  [[ "$line" != *"!!"* ]]
  [[ "$line" == *"--"* ]]
}

@test "Litestream empty replica dir: WARN once the DB is older than the threshold" {
  _migration_applied '-10 days'
  _enable_litestream

  _run_doctor
  line="$(_ls_line)"
  [[ "$line" == *"replica dir missing or empty"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "young DB with schema_migrations dropped: unreadable ledger is NOT fresh, WARN" {
  sqlite3 "$CAST_DB_PATH" "DROP TABLE schema_migrations;"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" == *"!!"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
}

@test "unparseable applied_at ('not-a-date') is NOT fresh, WARN" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES (1, 'not-a-date');"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "CAST_DB_PATH containing '#' (URI metachar) with an old ledger still WARNs" {
  mkdir -p "${BATS_TEST_TMPDIR}/a#b"
  export CAST_DB_PATH="${BATS_TEST_TMPDIR}/a#b/cast.db"
  _create_minimal_db "$CAST_DB_PATH"
  _migration_applied '-10 days'

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "non-numeric CAST_BACKUP_MAX_AGE_HOURS falls back to 48 without a bash error" {
  _migration_applied 'now'

  EXTRA_ENV="CAST_BACKUP_MAX_AGE_HOURS=48h" _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet"* ]]
  [[ "$line" == *"--"* ]]
  [[ "$line" != *"!!"* ]]
  refute_output --partial "syntax error"
  refute_output --partial "value too great"
}

@test "CAST_DB_PATH containing '#' with a young ledger is read correctly and reads fresh" {
  mkdir -p "${BATS_TEST_TMPDIR}/a#b"
  export CAST_DB_PATH="${BATS_TEST_TMPDIR}/a#b/cast.db"
  _create_minimal_db "$CAST_DB_PATH"
  _migration_applied 'now'

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet (new install"* ]]
  [[ "$line" == *"--"* ]]
  [[ "$line" != *"!!"* ]]
}

@test "empty-string applied_at row (young DB) is NOT fresh, WARN" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('1', '');"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" == *"!!"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
}

@test "mixed-format ledger rows both 10 days old (space form + ISO-Z form) WARN" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('1', datetime('now','-10 days'));"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('2', strftime('%Y-%m-%dT%H:%M:%SZ','now','-10 days'));"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" != *"no snapshot yet"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "one old row among young rows still reads old (every row is parsed, oldest wins)" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('1', strftime('%Y-%m-%dT%H:%M:%SZ','now','-10 days'));"
  sqlite3 "$CAST_DB_PATH" "INSERT INTO schema_migrations (version, applied_at) VALUES ('2', datetime('now'));"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot found in"* ]]
  [[ "$line" == *"!!"* ]]
}

@test "CAST_BACKUP_MAX_AGE_HOURS=08 (octal-looking) falls back to 48, no arithmetic error" {
  _migration_applied 'now'

  EXTRA_ENV="CAST_BACKUP_MAX_AGE_HOURS=08" _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet"* ]]
  [[ "$line" == *"--"* ]]
  [[ "$line" != *"!!"* ]]
  refute_output --partial "syntax error"
  refute_output --partial "value too great"
}

@test "idle WAL-mode DB (no sidecars) is readable on the system /usr/bin/python3: fresh reads INFO" {
  [ -x /usr/bin/python3 ] || skip "/usr/bin/python3 absent on this platform"
  # Pin python3 to the system interpreter (a ?mode=ro URI open fails on its idle WAL DBs).
  ln -s /usr/bin/python3 "${FAKE_BIN}/python3"
  sqlite3 "$CAST_DB_PATH" "PRAGMA journal_mode=WAL;" >/dev/null
  _migration_applied 'now'
  sqlite3 "$CAST_DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  rm -f "${CAST_DB_PATH}-wal" "${CAST_DB_PATH}-shm"
  [ "$(sqlite3 "$CAST_DB_PATH" 'PRAGMA journal_mode;')" = "wal" ]
  rm -f "${CAST_DB_PATH}-wal" "${CAST_DB_PATH}-shm"

  # The sqlite3 CLI can leave -wal/-shm sidecars behind after a read, which would
  # hide the failure. Wrap it so every doctor-side call leaves the DB idle (no
  # sidecars) by the time the age helper runs -- the shape of a cleanly closed DB.
  # Deleting the sidecars is safe ONLY because the DB was TRUNCATE-checkpointed above and
  # doctor's CLI calls are read-only; a wrapper like this must never front a writer.
  real_sqlite3="$(command -v sqlite3)"
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\nrm -f "%s-wal" "%s-shm"\nexit $rc\n' \
    "$real_sqlite3" "$CAST_DB_PATH" "$CAST_DB_PATH" > "${FAKE_BIN}/sqlite3"
  chmod +x "${FAKE_BIN}/sqlite3"

  _run_doctor
  line="$(_backup_line)"
  [[ "$line" == *"Backups: no snapshot yet (new install"* ]]
  [[ "$line" == *"--"* ]]
  [[ "$line" != *"!!"* ]]
}
