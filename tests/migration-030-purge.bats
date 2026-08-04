#!/usr/bin/env bats
# Tests for scripts/migrations/030_purge_truncated_quality_gates.sql
# Covers: TRUNCATED rows deleted, non-TRUNCATED rows preserved, idempotency.
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIGRATION="$REPO_DIR/scripts/migrations/030_purge_truncated_quality_gates.sql"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME

  export TEST_DB="$HOME/qg-test.db"

  # Create quality_gates table with id, status_line, gate_type
  sqlite3 "$TEST_DB" "
    CREATE TABLE quality_gates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      status_line TEXT,
      gate_type TEXT
    );
  "
}

teardown() {
  rm -f "$TEST_DB"
  teardown_temp_home
}

# --- TRUNCATED rows deleted ---

@test "migration deletes rows where status_line='TRUNCATED'" {
  # Seed: 3 TRUNCATED + 2 non-TRUNCATED
  sqlite3 "$TEST_DB" "
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('TRUNCATED', 'truncation_detected');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('TRUNCATED', 'truncation_detected');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('TRUNCATED', 'truncation_detected');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('APPROVED', 'reviewer');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('REJECTED', 'reviewer');
  "

  # Apply migration
  sqlite3 "$TEST_DB" < "$MIGRATION"

  # Verify: 0 TRUNCATED rows remain
  truncated_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates WHERE status_line='TRUNCATED';")
  [[ "$truncated_count" == "0" ]] || { echo "Expected 0 TRUNCATED rows, got $truncated_count"; return 1; }

  # Verify: 2 non-TRUNCATED rows remain
  total_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;")
  [[ "$total_count" == "2" ]] || { echo "Expected 2 rows total, got $total_count"; return 1; }
}

# --- Non-TRUNCATED rows preserved ---

@test "migration preserves all non-TRUNCATED rows" {
  # Seed with various statuses
  sqlite3 "$TEST_DB" "
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('APPROVED', 'reviewer');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('REJECTED', 'reviewer');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('PENDING', 'reviewer');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('TRUNCATED', 'truncation_detected');
  "

  # Apply migration
  sqlite3 "$TEST_DB" < "$MIGRATION"

  # Verify: the 3 non-TRUNCATED rows are all intact
  rows=$(sqlite3 "$TEST_DB" "SELECT status_line FROM quality_gates ORDER BY status_line;")
  expected="APPROVED
PENDING
REJECTED"
  [[ "$rows" == "$expected" ]] || { echo "Rows mismatch"; echo "Expected: $expected"; echo "Got: $rows"; return 1; }
}

# --- Idempotent: running twice is a no-op ---

@test "migration is idempotent — running twice deletes nothing further" {
  # Seed with mixed rows
  sqlite3 "$TEST_DB" "
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('TRUNCATED', 'truncation_detected');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('APPROVED', 'reviewer');
  "

  # Apply migration
  sqlite3 "$TEST_DB" < "$MIGRATION"

  # Capture row count after first run
  count_after_first=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;")

  # Apply migration again
  sqlite3 "$TEST_DB" < "$MIGRATION"

  # Capture row count after second run
  count_after_second=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;")

  # Verify counts are identical (no rows deleted in second run)
  [[ "$count_after_first" == "$count_after_second" ]] || { echo "Counts differ: $count_after_first vs $count_after_second"; return 1; }
  [[ "$count_after_first" == "1" ]] || { echo "Expected 1 row to remain, got $count_after_first"; return 1; }
}

# --- Table with no TRUNCATED rows ---

@test "migration on table with no TRUNCATED rows is a clean no-op" {
  # Seed: only non-TRUNCATED
  sqlite3 "$TEST_DB" "
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('APPROVED', 'reviewer');
    INSERT INTO quality_gates (status_line, gate_type) VALUES ('REJECTED', 'reviewer');
  "

  # Capture row count before
  count_before=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;")

  # Apply migration
  sqlite3 "$TEST_DB" < "$MIGRATION"

  # Capture row count after
  count_after=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM quality_gates;")

  # Verify count unchanged
  [[ "$count_before" == "$count_after" ]] || { echo "Row count changed: $count_before -> $count_after"; return 1; }
}
