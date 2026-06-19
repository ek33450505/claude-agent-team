#!/usr/bin/env bats
# cast-memory-facts-write.bats — Tests for the hardened Facts-write script.
#
# Isolation: uses setup_temp_home/teardown_temp_home (HOME redirected to tmp).
# DB:        temp cast.db with agent_memories schema, never touches real cast.db.
# Coverage:
#   (a) new fact inserted; confidence capped at 0.8 even when Facts claims 1.0
#   (b) protected memory (last_validated_at set OR confidence>=0.9) is NOT overwritten
#   (c) non-protected memory, different content → supersession (old valid_to set, new row)
#   (d) identical content re-affirm → no new row, valid_to NOT reset

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-memory-facts-write.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create agent_memories table in $CAST_DB_PATH
init_db() {
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  agent             TEXT NOT NULL,
  project           TEXT,
  type              TEXT,
  name              TEXT,
  description       TEXT,
  content           TEXT,
  created_at        TEXT,
  updated_at        TEXT,
  confidence        REAL DEFAULT 1.0,
  importance        REAL DEFAULT 0.5,
  decay_rate        REAL DEFAULT 0.0,
  valid_from        TEXT,
  valid_to          TEXT,
  embedding         BLOB,
  last_validated_at TEXT,
  retrieval_count   INTEGER DEFAULT 0
);
SQL
}

# Run the script with a given CAST_STOP_RESPONSE_TEXT.
# Extra env overrides can be passed as "KEY=VALUE" args after $1.
run_script() {
  local response_text="$1"
  shift
  CAST_STOP_AGENT="${CAST_STOP_AGENT:-test-writer}" \
  CAST_STOP_RESPONSE_TEXT="$response_text" \
  CAST_DB_PATH="$CAST_DB_PATH" \
  CAST_PROJECT_ROOT="$REPO_DIR" \
  "$@" \
  python3 "$SCRIPT" 2>&1
}

# Query helper: run a sqlite3 SELECT and return value.
# $1 = SQL query string
db_query() {
  sqlite3 "$CAST_DB_PATH" "$1"
}

# Seed a memory row directly into the DB.
# Usage: seed_memory name content confidence [last_validated_at]
seed_memory() {
  local name="$1"
  local content="$2"
  local confidence="$3"
  local lva="${4:-}"  # last_validated_at, empty = NULL
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  local lva_sql; lva_sql="NULL"
  if [[ -n "$lva" ]]; then
    lva_sql="'$lva'"
  fi
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at, confidence, valid_from, last_validated_at) \
     VALUES ('test-writer', 'claude-agent-team', 'project', '$name', '$content', '$content', '$now', '$now', $confidence, '$now', $lva_sql);"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
  init_db
  export CAST_STOP_AGENT="test-writer"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# (a) New fact inserted; confidence capped at SUBAGENT_CONFIDENCE_CAP (0.8)
# ---------------------------------------------------------------------------

@test "(a) new fact is inserted with confidence capped at 0.8 when claimed=1.0" {
  local response
  response="## Facts
name: new-discovery | type: project | content: Some important discovery about the system | confidence: 1.0"

  run run_script "$response"
  assert_success

  # Row must exist
  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='new-discovery' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$count" -eq 1 ]]

  # Confidence must be capped at 0.8, not 1.0
  local conf
  conf="$(db_query "SELECT confidence FROM agent_memories WHERE name='new-discovery' AND agent='test-writer' AND valid_to IS NULL;")"
  # Use python3 for float comparison
  python3 -c "import sys; c=float('$conf'); sys.exit(0 if c == 0.8 else 1)"
}

@test "(a) new fact with no confidence field defaults to cap (0.8)" {
  local response
  response="## Facts
name: another-fact | type: feedback | content: User prefers concise responses"

  run run_script "$response"
  assert_success

  local conf
  conf="$(db_query "SELECT confidence FROM agent_memories WHERE name='another-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  python3 -c "import sys; c=float('$conf'); sys.exit(0 if c == 0.8 else 1)"
}

@test "(a) negative confidence is floored to 0.0" {
  local response
  response="## Facts
name: neg-conf-fact | type: project | content: A fact with an adversarial confidence | confidence: -5.0"

  run run_script "$response"
  assert_success

  local conf
  conf="$(db_query "SELECT confidence FROM agent_memories WHERE name='neg-conf-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  python3 -c "import sys; c=float('$conf'); sys.exit(0 if c == 0.0 else 1)"
}

@test "(a) confidence below cap is preserved, not raised" {
  local response
  response="## Facts
name: low-conf-fact | type: project | content: A weakly-held observation | confidence: 0.5"

  run run_script "$response"
  assert_success

  local conf
  conf="$(db_query "SELECT confidence FROM agent_memories WHERE name='low-conf-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  python3 -c "import sys; c=float('$conf'); sys.exit(0 if c == 0.5 else 1)"
}

@test "(a) [CAST-MEMORY] write summary emitted to stderr on success" {
  local response
  response="## Facts
name: summary-test | type: project | content: A fact worth recording"

  run run_script "$response"
  assert_success
  assert_output --partial "[CAST-MEMORY]"
}

# ---------------------------------------------------------------------------
# (b) Protected memories are NOT overwritten
#     Protected = last_validated_at IS NOT NULL OR confidence >= 0.9
# ---------------------------------------------------------------------------

@test "(b) protected memory (last_validated_at set) is not overwritten; refusal logged" {
  seed_memory "trusted-fact" "Original trusted content" "0.7" "2026-01-01T00:00:00Z"

  local response
  response="## Facts
name: trusted-fact | type: project | content: INJECTED malicious replacement"

  run run_script "$response"
  assert_success

  # Content must remain unchanged
  local content
  content="$(db_query "SELECT content FROM agent_memories WHERE name='trusted-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$content" == "Original trusted content" ]]

  # No new row must have been inserted
  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='trusted-fact' AND agent='test-writer';")"
  [[ "$count" -eq 1 ]]

  # Refusal must be logged to stderr
  assert_output --partial "refused overwrite of trusted memory 'trusted-fact'"
}

@test "(b) protected memory (confidence >= 0.9, no last_validated_at) is not overwritten" {
  seed_memory "high-conf-fact" "High-confidence established content" "0.95"

  local response
  response="## Facts
name: high-conf-fact | type: project | content: Attempted overwrite with confidence:1.0 | confidence: 1.0"

  run run_script "$response"
  assert_success

  local content
  content="$(db_query "SELECT content FROM agent_memories WHERE name='high-conf-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$content" == "High-confidence established content" ]]

  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='high-conf-fact' AND agent='test-writer';")"
  [[ "$count" -eq 1 ]]

  assert_output --partial "refused overwrite of trusted memory 'high-conf-fact'"
}

@test "(b) a superseded old row (valid_to set) does not protect the slot — new row inserts" {
  # A superseded row has valid_to set; it should NOT block new writes to that (agent, name)
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, project, type, name, description, content, created_at, updated_at, confidence, valid_from, valid_to, last_validated_at) \
     VALUES ('test-writer', 'claude-agent-team', 'project', 'superseded-slot', 'old', 'old content', '$now', '$now', 0.5, '$now', '$now', NULL);"

  local response
  response="## Facts
name: superseded-slot | type: project | content: Fresh replacement for vacant slot"

  run run_script "$response"
  assert_success

  # A new current row (valid_to IS NULL) should exist
  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='superseded-slot' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$count" -eq 1 ]]

  local content
  content="$(db_query "SELECT content FROM agent_memories WHERE name='superseded-slot' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$content" == "Fresh replacement for vacant slot" ]]
}

# ---------------------------------------------------------------------------
# (c) Non-protected memory with DIFFERENT content → non-destructive supersession
#     Old row: valid_to set (content preserved). New row: valid_to IS NULL, capped confidence.
# ---------------------------------------------------------------------------

@test "(c) different content on non-protected memory triggers non-destructive supersession" {
  seed_memory "evolving-fact" "Original content that will be superseded" "0.5"

  local response
  response="## Facts
name: evolving-fact | type: project | content: Updated content with new information | confidence: 0.7"

  run run_script "$response"
  assert_success

  # Old row must have valid_to set (superseded, content preserved)
  local superseded_content
  superseded_content="$(db_query "SELECT content FROM agent_memories WHERE name='evolving-fact' AND agent='test-writer' AND valid_to IS NOT NULL;")"
  [[ "$superseded_content" == "Original content that will be superseded" ]]

  # New current row must exist with updated content
  local new_content
  new_content="$(db_query "SELECT content FROM agent_memories WHERE name='evolving-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  [[ "$new_content" == "Updated content with new information" ]]

  # Total rows = 2 (old superseded + new current)
  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='evolving-fact' AND agent='test-writer';")"
  [[ "$count" -eq 2 ]]

  # New row confidence is capped at 0.8 (claimed 0.7 < cap, so 0.7 is preserved)
  local conf
  conf="$(db_query "SELECT confidence FROM agent_memories WHERE name='evolving-fact' AND agent='test-writer' AND valid_to IS NULL;")"
  python3 -c "import sys; c=float('$conf'); sys.exit(0 if c == 0.7 else 1)"
}

@test "(c) superseded old row is preserved in DB — content not destroyed" {
  seed_memory "audit-trail-fact" "Audit-critical original text" "0.6"

  local response
  response="## Facts
name: audit-trail-fact | type: project | content: Revised version of the fact"

  run run_script "$response"
  assert_success

  # The old row's content must still be readable (audit trail)
  local old_exists
  old_exists="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='audit-trail-fact' AND content='Audit-critical original text' AND valid_to IS NOT NULL;")"
  [[ "$old_exists" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# (d) Identical content re-affirm → only updated_at bumped; no new row; valid_to NOT reset
# ---------------------------------------------------------------------------

@test "(d) identical content re-affirm does not insert a new row" {
  seed_memory "stable-fact" "Stable content that never changes" "0.5"
  local before_count
  before_count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='stable-fact' AND agent='test-writer';")"

  local response
  response="## Facts
name: stable-fact | type: project | content: Stable content that never changes"

  run run_script "$response"
  assert_success

  local after_count
  after_count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='stable-fact' AND agent='test-writer';")"
  [[ "$after_count" -eq "$before_count" ]]
}

@test "(d) identical content re-affirm does NOT set valid_to on the existing row" {
  seed_memory "pinned-fact" "Pinned stable content" "0.4"

  local response
  response="## Facts
name: pinned-fact | type: project | content: Pinned stable content"

  run run_script "$response"
  assert_success

  local valid_to
  valid_to="$(db_query "SELECT valid_to FROM agent_memories WHERE name='pinned-fact' AND agent='test-writer';")"
  # valid_to must remain NULL (empty string from sqlite3 means NULL)
  [[ -z "$valid_to" ]]
}

# ---------------------------------------------------------------------------
# Edge cases — malformed / empty Facts blocks
# ---------------------------------------------------------------------------

@test "empty response exits 0 silently" {
  run run_script ""
  assert_success
  assert_output ""
}

@test "response with no Facts block exits 0 silently" {
  local response
  response="## Work Log
- Did some work

Status: DONE"

  run run_script "$response"
  assert_success
  assert_output ""
}

@test "Facts line with invalid type is skipped silently" {
  local response
  response="## Facts
name: bad-type-fact | type: invalid_type | content: This should be skipped"

  run run_script "$response"
  assert_success

  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='bad-type-fact';")"
  [[ "$count" -eq 0 ]]
}

@test "MAX_FACTS=5 cap: only first 5 valid facts are written" {
  local response
  response="## Facts
name: fact-1 | type: project | content: Content one
name: fact-2 | type: project | content: Content two
name: fact-3 | type: project | content: Content three
name: fact-4 | type: project | content: Content four
name: fact-5 | type: project | content: Content five
name: fact-6 | type: project | content: Content six should be skipped"

  run run_script "$response"
  assert_success

  local count
  count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE agent='test-writer' AND valid_to IS NULL;")"
  [[ "$count" -eq 5 ]]

  local skipped
  skipped="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='fact-6';")"
  [[ "$skipped" -eq 0 ]]
}
