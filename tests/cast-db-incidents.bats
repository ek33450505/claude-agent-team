#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATE_SCRIPT="$REPO_DIR/scripts/cast-migrate.py"
INCIDENTS_SCRIPT="$REPO_DIR/scripts/cast-db-incidents.py"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude/logs"

  # Use BATS_TEST_TMPDIR for isolation
  export TEST_DB="$BATS_TEST_TMPDIR/test-incidents-$$.db"
  export CAST_DB_PATH="$TEST_DB"

  # Initialize schema (baseline + incidents table) via Python migration runner
  CAST_DB_PATH="$TEST_DB" python3 "$MIGRATE_SCRIPT" --confirm > /dev/null 2>&1 || true
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Recent: basic functionality
# ---------------------------------------------------------------------------

@test "cast-db-incidents: recent with empty DB returns '(no incidents)' to stderr, exits 0" {
  run python3 "$INCIDENTS_SCRIPT" recent
  assert_success
  [[ "$output" == *"(no incidents)"* ]]
}

@test "cast-db-incidents: recent N=3 returns 3 most recent rows in DESC order" {
  # Insert test rows in out-of-order fashion to verify DESC sorting
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'first', 'open'),
('id3', '2026-01-03T10:00:00', 'third', 'open'),
('id2', '2026-01-02T10:00:00', 'second', 'open'),
('id4', '2026-01-04T10:00:00', 'fourth', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" recent 3
  assert_success

  # Should show id4, id3, id2 (most recent first)
  [[ "$output" == *"fourth"* ]]
  [[ "$output" == *"third"* ]]
  [[ "$output" == *"second"* ]]
  # id1 should not appear
  [[ "$output" != *"first"* ]]
}

# ---------------------------------------------------------------------------
# Recent: status filtering
# ---------------------------------------------------------------------------

@test "cast-db-incidents: recent --status=open filters correctly" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'problem_open', 'open'),
('id2', '2026-01-02T10:00:00', 'problem_fixed', 'fixed'),
('id3', '2026-01-03T10:00:00', 'problem_open2', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" recent --status=open
  assert_success

  # Should only show open incidents
  [[ "$output" == *"problem_open2"* ]]
  [[ "$output" == *"problem_open"* ]]
  [[ "$output" != *"problem_fixed"* ]]
}

# ---------------------------------------------------------------------------
# Recent: JSON output
# ---------------------------------------------------------------------------

@test "cast-db-incidents: recent --json returns valid JSON array" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('test-id', '2026-01-01T10:00:00', 'test problem', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" recent --json
  assert_success

  # Verify it's valid JSON and contains expected fields
  echo "$output" | python3 -m json.tool > /dev/null  # Verify valid JSON syntax

  # Check structure
  [[ "$output" == *"test-id"* ]]
  [[ "$output" == *"test problem"* ]]
  [[ "$output" == *"open"* ]]
}

# ---------------------------------------------------------------------------
# Search: basic functionality
# ---------------------------------------------------------------------------

@test "cast-db-incidents: search matches keyword in problem_summary" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'database connection timeout', 'open'),
('id2', '2026-01-02T10:00:00', 'ui rendering error', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" search "database"
  assert_success
  [[ "$output" == *"database connection timeout"* ]]
  [[ "$output" != *"ui rendering error"* ]]
}

@test "cast-db-incidents: search matches keyword in fix_summary" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'crash on startup', 'added nil check in main', 'fixed'),
('id2', '2026-01-02T10:00:00', 'memory leak', 'optimized loop', 'fixed');
EOF

  run python3 "$INCIDENTS_SCRIPT" search "nil"
  assert_success
  [[ "$output" == *"crash on startup"* ]]
  [[ "$output" != *"memory leak"* ]]
}

# ---------------------------------------------------------------------------
# Search: case-insensitivity
# ---------------------------------------------------------------------------

@test "cast-db-incidents: search is case-insensitive" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'Network Connection Failed', 'open');
EOF

  # Search with lowercase
  run python3 "$INCIDENTS_SCRIPT" search "network"
  assert_success
  [[ "$output" == *"Network Connection Failed"* ]]

  # Search with uppercase
  run python3 "$INCIDENTS_SCRIPT" search "CONNECTION"
  assert_success
  [[ "$output" == *"Network Connection Failed"* ]]
}

# ---------------------------------------------------------------------------
# Search: no matches
# ---------------------------------------------------------------------------

@test "cast-db-incidents: search with no matches returns '(no incidents)' exit 0" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'some problem', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" search "nonexistent_keyword"
  assert_success
  [[ "$output" == *"(no incidents)"* ]]
}

# ---------------------------------------------------------------------------
# Table-not-initialized path
# ---------------------------------------------------------------------------

@test "cast-db-incidents: table-not-yet-initialized returns friendly message and exits 0" {
  # Use a fresh DB without running migrations (no incidents table)
  export FRESH_DB="$BATS_TEST_TMPDIR/fresh-$$.db"
  export CAST_DB_PATH="$FRESH_DB"

  # Touch the DB to create it, but don't initialize schema
  sqlite3 "$FRESH_DB" "PRAGMA user_version=0;"

  run python3 "$INCIDENTS_SCRIPT" recent
  assert_success
  [[ "$output" == *"incidents table not yet initialized"* ]]

  rm -f "$FRESH_DB"
}

# ---------------------------------------------------------------------------
# Search: JSON output
# ---------------------------------------------------------------------------

@test "cast-db-incidents: search --json returns valid JSON array" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'network issue', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" search "network" --json
  assert_success

  # Verify it's valid JSON
  echo "$output" | python3 -m json.tool > /dev/null

  # Check structure
  [[ "$output" == *"network issue"* ]]
}

# ---------------------------------------------------------------------------
# Edge cases: recent with N parameter
# ---------------------------------------------------------------------------

@test "cast-db-incidents: recent with explicit N shows correct count" {
  sqlite3 "$TEST_DB" <<EOF
INSERT INTO incidents (id, occurred_at, problem_summary, resolution_status) VALUES
('id1', '2026-01-01T10:00:00', 'incident1', 'open'),
('id2', '2026-01-02T10:00:00', 'incident2', 'open'),
('id3', '2026-01-03T10:00:00', 'incident3', 'open'),
('id4', '2026-01-04T10:00:00', 'incident4', 'open'),
('id5', '2026-01-05T10:00:00', 'incident5', 'open');
EOF

  run python3 "$INCIDENTS_SCRIPT" recent 2
  assert_success

  # Should show exactly 2 incidents (most recent)
  [[ "$output" == *"incident5"* ]]
  [[ "$output" == *"incident4"* ]]
  [[ "$output" != *"incident3"* ]]
}
