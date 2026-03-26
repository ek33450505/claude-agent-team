#!/usr/bin/env bats
# Tests for cast-memory-write.sh and cast-memory-query.sh
#
# Coverage:
#   - cast-memory-write.sh: happy path write, deduplication, missing args
#   - cast-memory-query.sh: no-results returns [], happy path match, filter by agent

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WRITE_SH="$REPO_DIR/scripts/cast-memory-write.sh"
QUERY_SH="$REPO_DIR/scripts/cast-memory-query.sh"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"
  # Disable Ollama for tests (no embedding server in CI)
  export OLLAMA_URL="http://localhost:19999"

  mkdir -p "$HOME/.claude"
  # Initialize the DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH
  unset OLLAMA_URL
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

@test "cast-memory-write: written memory appears in cast-memory-query results" {
  bash "$WRITE_SH" "query-agent" "project" "searchable-memory" "Unique searchable keyword zxqvbm." --project "proj1"

  run bash "$QUERY_SH" "zxqvbm" --agent "query-agent" --project "proj1"
  assert_success
  assert_output --partial "searchable-memory"
  assert_output --partial "zxqvbm"
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

# ---------------------------------------------------------------------------
# cast-memory-query.sh — no results returns empty JSON array
# ---------------------------------------------------------------------------

@test "cast-memory-query: returns [] when no matches found" {
  run bash "$QUERY_SH" "absolutely_no_match_xyzzy_999"
  assert_success
  assert_output "[]"
}

@test "cast-memory-query: returns [] when DB does not exist" {
  export CAST_DB_PATH="$HOME/.claude/nonexistent.db"
  run bash "$QUERY_SH" "anything"
  assert_success
  assert_output "[]"
}

@test "cast-memory-query: returns [] when called with empty query" {
  run bash "$QUERY_SH" ""
  assert_success
  assert_output "[]"
}

# ---------------------------------------------------------------------------
# cast-memory-query.sh — happy path search
# ---------------------------------------------------------------------------

@test "cast-memory-query: finds memory by content keyword" {
  bash "$WRITE_SH" "finder-agent" "feedback" "findable" "The quick brown fox jumps uniquely." --project "fp"

  run bash "$QUERY_SH" "brown fox" --agent "finder-agent"
  assert_success
  assert_output --partial "findable"
}

@test "cast-memory-query: --limit filters result count" {
  bash "$WRITE_SH" "limiter" "feedback" "m1" "limit test alpha"   --project "lp"
  bash "$WRITE_SH" "limiter" "feedback" "m2" "limit test beta"    --project "lp"
  bash "$WRITE_SH" "limiter" "feedback" "m3" "limit test gamma"   --project "lp"

  run bash "$QUERY_SH" "limit test" --agent "limiter" --limit 2
  assert_success
  # JSON array with at most 2 items — count opening braces for objects
  local obj_count
  obj_count="$(echo "$output" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  [ "$obj_count" -le 2 ]
}

@test "cast-memory-query: output is valid JSON array" {
  bash "$WRITE_SH" "json-agent" "project" "json-check" "Content for JSON validation." --project "jp"

  run bash "$QUERY_SH" "JSON validation" --agent "json-agent"
  assert_success

  # Validate that output is a JSON array
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)' 2>/dev/null
}

@test "cast-memory-query: --type filter excludes wrong types" {
  bash "$WRITE_SH" "filter-a" "user"     "type-user-mem"     "type filter test" --project "tfp"
  bash "$WRITE_SH" "filter-a" "feedback" "type-feedback-mem" "type filter test" --project "tfp"

  run bash "$QUERY_SH" "type filter test" --agent "filter-a" --type "user"
  assert_success
  assert_output --partial "type-user-mem"
  refute_output --partial "type-feedback-mem"
}
