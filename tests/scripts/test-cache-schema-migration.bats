#!/usr/bin/env bats
# test-cache-schema-migration.bats — CAST schema migration for cache token columns
# Tests: idempotent ALTER TABLE for cache_read_input_tokens and cache_creation_input_tokens

setup() {
  export CAST_DB_PATH="/tmp/cast-test-cache-migration-$$.db"
  rm -f "$CAST_DB_PATH"
}

teardown() {
  rm -f "$CAST_DB_PATH"
}

@test "cast-db-init.sh creates cache token columns on fresh install" {
  bash scripts/cast-db-init.sh --db "$CAST_DB_PATH"

  # Verify both cache columns exist
  columns="$(sqlite3 "$CAST_DB_PATH" "PRAGMA table_info(agent_runs);")"

  [[ "$columns" =~ cache_read_input_tokens ]]
  [[ "$columns" =~ cache_creation_input_tokens ]]
}

@test "cache columns accept NULL values (non-cached API calls)" {
  bash scripts/cast-db-init.sh --db "$CAST_DB_PATH"

  # Insert a row without cache tokens
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, status) VALUES ('sess-1', 'commit', 'DONE');
SQL

  # Verify NULL is accepted
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT cache_read_input_tokens, cache_creation_input_tokens FROM agent_runs WHERE agent='commit';")"
  [[ "$result" == "|" ]]  # Both NULL, pipe-delimited
}

@test "cache columns accept INTEGER values (cached API calls)" {
  bash scripts/cast-db-init.sh --db "$CAST_DB_PATH"

  # Insert a row with cache tokens
  sqlite3 "$CAST_DB_PATH" <<'SQL'
INSERT INTO agent_runs (session_id, agent, status, cache_read_input_tokens, cache_creation_input_tokens)
VALUES ('sess-1', 'commit', 'DONE', 1234, 5678);
SQL

  result="$(sqlite3 "$CAST_DB_PATH" "SELECT cache_read_input_tokens, cache_creation_input_tokens FROM agent_runs WHERE agent='commit';")"
  [[ "$result" == "1234|5678" ]]
}

@test "ALTER TABLE is idempotent for cache columns" {
  bash scripts/cast-db-init.sh --db "$CAST_DB_PATH"

  # Run init again — should not fail even if columns exist
  bash scripts/cast-db-init.sh --db "$CAST_DB_PATH"

  # Verify columns still exist and DB is healthy
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_runs;")"
  [[ "$result" == "0" ]]
}
