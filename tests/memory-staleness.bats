#!/usr/bin/env bats
# BATS tests for the memory staleness sweep and cast memory CLI.
#
# These tests provision the DB with the REAL cast-db-init.sh schema, whose
# canonical validation column is `last_validated_at`. The previous version of
# this file hand-rolled an agent_memories fixture using a divergent column name
# (`last_verified`) and ran the now-retired cast-memory-migration-001.sh. That
# divergence gave false confidence: the sweep passed here while being completely
# broken against production (it queried `last_verified`, which production never
# had, and errored out on every run). Provisioning via cast-db-init.sh ties the
# tests to the schema the sweep actually runs against.

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  export CAST_SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../scripts"

  mkdir -p "$HOME/.claude/logs"
  bash "$CAST_SCRIPTS_DIR/cast-db-init.sh" --db "$CAST_DB_PATH" >/dev/null 2>&1
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

@test "agent_memories uses canonical last_validated_at column (not legacy last_verified)" {
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM pragma_table_info('agent_memories') WHERE name='last_validated_at';"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # The legacy name must be gone — its presence would re-introduce the drift.
  run sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM pragma_table_info('agent_memories') WHERE name='last_verified';"
  [ "$output" = "0" ]
}

@test "sweep runs clean (exit 0) and sets last_validated_at for NULL entries" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, content, confidence, last_validated_at) VALUES ('test-agent', 'feedback', 'test-memory', 'This is a test memory.', 1.0, NULL);"

  run bash "$CAST_SCRIPTS_DIR/cast-memory-staleness-sweep.sh"
  # Regression: this used to fail with "no such column: last_verified" and exit 1.
  [ "$status" -eq 0 ]

  local result
  result="$(sqlite3 "$CAST_DB_PATH" "SELECT last_validated_at FROM agent_memories WHERE name='test-memory';" 2>/dev/null || true)"
  [ -n "$result" ]
}

@test "confidence decreases for entries with non-existent paths" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, content, confidence, last_validated_at) VALUES ('test-agent', 'feedback', 'broken-ref', 'See /path/to/nonexistent.sh for details.', 1.0, NULL);"

  bash "$CAST_SCRIPTS_DIR/cast-memory-staleness-sweep.sh" 2>/dev/null || true

  local conf
  conf="$(sqlite3 "$CAST_DB_PATH" "SELECT confidence FROM agent_memories WHERE name='broken-ref';" 2>/dev/null || true)"
  # Should be 1.0 - 0.2 = 0.8 due to the missing path reference.
  [[ "$conf" == "0.8" ]]
}

@test "cast memory list query works against canonical schema" {
  sqlite3 "$CAST_DB_PATH" "INSERT INTO agent_memories (agent, type, name, description, content, confidence) VALUES ('test', 'feedback', 'test-mem', 'A test', 'Test content', 0.9);"

  python3 - "$CAST_DB_PATH" <<'PYEOF'
import sys, sqlite3
conn = sqlite3.connect(sys.argv[1])
conn.row_factory = sqlite3.Row
rows = conn.execute("SELECT id, agent, type, name FROM agent_memories").fetchall()
conn.close()
assert len(rows) == 1
assert rows[0]['agent'] == 'test'
PYEOF
}
