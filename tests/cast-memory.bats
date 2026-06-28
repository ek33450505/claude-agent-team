#!/usr/bin/env bats
# Tests for cast-memory-write.sh
#
# Coverage:
#   - cast-memory-write.sh: happy path write, deduplication, missing args

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WRITE_SH="$REPO_DIR/scripts/cast-memory-write.sh"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  # Disable embedding service for tests

  mkdir -p "$HOME/.claude"
  # Initialize the DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# cast-memory-write.sh — happy path
# ---------------------------------------------------------------------------

@test "cast-memory-write: writes a memory and prints confirmation" {
  run bash "$WRITE_SH" "test-agent" "feedback" "test-finding" "This is a test memory content." --project "myproject"
  assert_success
  assert_output --partial "Memory written: test-finding"
}

@test "cast-memory-write: written memory is readable via sqlite3" {
  bash "$WRITE_SH" "test-agent" "feedback" "readable-finding" "Readable content for sqlite check." --project "testproject"

  local count
  count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE name='readable-finding';" 2>/dev/null)"
  [ "$count" -eq 1 ]
}

@test "cast-memory-write: written memory is queryable via sqlite3" {
  bash "$WRITE_SH" "query-agent" "project" "searchable-memory" "Unique searchable keyword zxqvbm." --project "proj1"

  run sqlite3 "$CAST_DB_PATH" "SELECT count(*) FROM agent_memories WHERE name='searchable-memory' AND content LIKE '%zxqvbm%';"
  assert_success
  assert_output "1"
}

@test "cast-memory-write: stores correct type, agent, project fields" {
  bash "$WRITE_SH" "security" "reference" "ref-memory" "Reference content here." --project "secure-proj"

  local type agent project
  type="$(sqlite3 "$CAST_DB_PATH" "SELECT type FROM agent_memories WHERE name='ref-memory';" 2>/dev/null)"
  agent="$(sqlite3 "$CAST_DB_PATH" "SELECT agent FROM agent_memories WHERE name='ref-memory';" 2>/dev/null)"
  project="$(sqlite3 "$CAST_DB_PATH" "SELECT project FROM agent_memories WHERE name='ref-memory';" 2>/dev/null)"

  [ "$type" = "reference" ]
  [ "$agent" = "security" ]
  [ "$project" = "secure-proj" ]
}

# ---------------------------------------------------------------------------
# cast-memory-write.sh — deduplication
# ---------------------------------------------------------------------------

@test "cast-memory-write: duplicate content updates updated_at, does not insert new row" {
  bash "$WRITE_SH" "dedup-agent" "feedback" "dedup-name" "Exact duplicate content." --project "p1"
  bash "$WRITE_SH" "dedup-agent" "feedback" "dedup-name" "Exact duplicate content." --project "p1"

  local count
  count="$(sqlite3 "$CAST_DB_PATH" "SELECT COUNT(*) FROM agent_memories WHERE content='Exact duplicate content.';" 2>/dev/null)"
  [ "$count" -eq 1 ]
}

@test "cast-memory-write: duplicate write prints 'Memory updated' not 'Memory written'" {
  bash "$WRITE_SH" "dedup-agent" "user" "dup-note" "Same content twice." --project "p2"
  run bash "$WRITE_SH" "dedup-agent" "user" "dup-note" "Same content twice." --project "p2"
  assert_success
  assert_output --partial "Memory updated (duplicate detected)"
}

# ---------------------------------------------------------------------------
# cast-memory-write.sh — argument validation
# ---------------------------------------------------------------------------

@test "cast-memory-write: exits 0 with missing args (never blocks workflow)" {
  run bash "$WRITE_SH"
  assert_success
}

@test "cast-memory-write: exits 0 with invalid type" {
  run bash "$WRITE_SH" "agent" "invalidtype" "name" "content"
  assert_success
  assert_output --partial "type must be one of"
}

@test "cast-memory-write: accepts all valid types" {
  run bash "$WRITE_SH" "a" "user"      "n1" "content1"
  assert_success
  run bash "$WRITE_SH" "a" "feedback"  "n2" "content2"
  assert_success
  run bash "$WRITE_SH" "a" "project"   "n3" "content3"
  assert_success
  run bash "$WRITE_SH" "a" "reference" "n4" "content4"
  assert_success
}

