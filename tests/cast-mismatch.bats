#!/usr/bin/env bats
# Tests for cast-mismatch-analyzer.sh and cast-memory-router.py
#
# Coverage:
#   - cast-mismatch-analyzer.sh: 11 signals for one route → proposal written
#   - cast-mismatch-analyzer.sh: 9 signals (below threshold 10) → no proposal
#   - cast-memory-router.py: matching memory returns correct agent
#   - cast-memory-router.py: no memories returns null agent

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MISMATCH_ANALYZER="$REPO_DIR/scripts/cast-mismatch-analyzer.sh"
MEMORY_ROUTER="$REPO_DIR/scripts/cast-memory-router.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export TEST_HOME
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export TEST_DB="$TEST_HOME/cast-test.db"
  export CAST_DB_PATH="$TEST_DB"

  mkdir -p "$TEST_HOME/.claude/config"

  # Create the DB with both required tables
  sqlite3 "$TEST_DB" <<'SCHEMA'
CREATE TABLE IF NOT EXISTS routing_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT,
  timestamp       TEXT,
  prompt_preview  TEXT,
  action          TEXT,
  matched_route   TEXT,
  match_type      TEXT,
  pattern         TEXT,
  confidence      TEXT,
  project         TEXT
);

CREATE TABLE IF NOT EXISTS mismatch_signals (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  routing_event_id    INTEGER,
  session_id          TEXT,
  original_prompt     TEXT,
  follow_up_prompt    TEXT,
  timestamp           TEXT,
  route_fired         TEXT,
  auto_detected       INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS agent_memories (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent       TEXT NOT NULL,
  project     TEXT,
  type        TEXT,
  name        TEXT,
  description TEXT,
  content     TEXT,
  created_at  TEXT,
  updated_at  TEXT,
  embedding   BLOB
);
SCHEMA
}

teardown() {
  rm -rf "$TEST_HOME"
  export HOME="$ORIG_HOME"
  unset CAST_DB_PATH TEST_DB TEST_HOME
}

# ---------------------------------------------------------------------------
# Helper: seed N mismatch_signals rows for a given route
# ---------------------------------------------------------------------------

_seed_mismatch_signals() {
  local route="$1"
  local count="$2"
  local i=1
  while [ "$i" -le "$count" ]; do
    sqlite3 "$TEST_DB" "INSERT INTO mismatch_signals (session_id, original_prompt, follow_up_prompt, timestamp, route_fired, auto_detected) VALUES ('sess1', 'original prompt ${i}', 'follow up prompt ${i}', datetime('now'), '${route}', 1);"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# cast-mismatch-analyzer.sh — 11 signals (above default threshold 10)
# ---------------------------------------------------------------------------

@test "cast-mismatch-analyzer: 11 signals produces a pending proposal with source=mismatch" {
  _seed_mismatch_signals "debugger" 11

  export PROPOSALS_PATH="$TEST_HOME/.claude/routing-proposals.json"

  # Override HOME so PROPOSALS_PATH resolves inside our temp dir
  run bash "$MISMATCH_ANALYZER"
  assert_success
  assert_output --partial "Mismatch proposals: 1 new"

  # Verify the proposals file was written
  [ -f "$TEST_HOME/.claude/routing-proposals.json" ]

  # Assert it has source=mismatch and status=pending for 'debugger'
  result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/routing-proposals.json') as f:
    proposals = json.load(f)
match = [p for p in proposals if p.get('route_fired') == 'debugger' and p.get('source') == 'mismatch' and p.get('status') == 'pending']
print('found' if match else 'missing')
")"
  [ "$result" = "found" ]
}

@test "cast-mismatch-analyzer: 11 signals sets correct id=mismatch-debugger" {
  _seed_mismatch_signals "debugger" 11

  run bash "$MISMATCH_ANALYZER"
  assert_success

  result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/routing-proposals.json') as f:
    proposals = json.load(f)
ids = [p['id'] for p in proposals]
print('found' if 'mismatch-debugger' in ids else 'missing')
")"
  [ "$result" = "found" ]
}

# ---------------------------------------------------------------------------
# cast-mismatch-analyzer.sh — 9 signals (below default threshold 10)
# ---------------------------------------------------------------------------

@test "cast-mismatch-analyzer: 9 signals (below threshold) produces no proposal" {
  _seed_mismatch_signals "code-writer" 9

  run bash "$MISMATCH_ANALYZER"
  assert_success
  assert_output --partial "Mismatch proposals: 0 new"

  # Proposals file should not contain a code-writer entry
  if [ -f "$TEST_HOME/.claude/routing-proposals.json" ]; then
    result="$(python3 -c "
import json
with open('$TEST_HOME/.claude/routing-proposals.json') as f:
    proposals = json.load(f)
match = [p for p in proposals if p.get('route_fired') == 'code-writer']
print('found' if match else 'missing')
")"
    [ "$result" = "missing" ]
  fi
}

@test "cast-mismatch-analyzer: custom --threshold 5 with 6 signals produces a proposal" {
  _seed_mismatch_signals "refactor-cleaner" 6

  run bash "$MISMATCH_ANALYZER" --threshold 5
  assert_success
  assert_output --partial "Mismatch proposals: 1 new"
}

# ---------------------------------------------------------------------------
# cast-memory-router.py — matching memory returns correct agent
# ---------------------------------------------------------------------------

@test "cast-memory-router: seeded memory with matching keywords returns correct agent" {
  # Seed a memory row with debug-related content
  sqlite3 "$TEST_DB" "INSERT INTO agent_memories (agent, type, name, description, content, created_at) VALUES ('debugger', 'feedback', 'debug-pattern', 'matches debugging prompts', 'debug error crash traceback stack failing test broken fix', '2026-03-27T00:00:00Z');"

  run python3 "$MEMORY_ROUTER" \
    --db "$TEST_DB" \
    --prompt "my tests are crashing with a traceback error" \
    --min-confidence 0.1
  assert_success

  # Output must be valid JSON with agent=debugger
  result="$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('agent', 'null'))
")"
  [ "$result" = "debugger" ]
}

@test "cast-memory-router: matching memory returns confidence >= threshold" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_memories (agent, type, name, description, content, created_at) VALUES ('debugger', 'feedback', 'debug-pattern', 'matches debugging prompts', 'debug error crash traceback stack failing test broken fix', '2026-03-27T00:00:00Z');"

  run python3 "$MEMORY_ROUTER" \
    --db "$TEST_DB" \
    --prompt "debug error crash" \
    --min-confidence 0.1
  assert_success

  confidence="$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('confidence', 0.0))
")"
  # Confidence must be >= 0.1
  python3 -c "assert float('$confidence') >= 0.1, f'confidence {$confidence} below threshold'"
}

# ---------------------------------------------------------------------------
# cast-memory-router.py — no memories returns null agent
# ---------------------------------------------------------------------------

@test "cast-memory-router: empty agent_memories table returns null agent" {
  run python3 "$MEMORY_ROUTER" \
    --db "$TEST_DB" \
    --prompt "debug my crashing test suite" \
    --min-confidence 0.1
  assert_success

  result="$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('agent'))
")"
  [ "$result" = "None" ]
}

@test "cast-memory-router: non-existent DB returns null agent" {
  run python3 "$MEMORY_ROUTER" \
    --db "/tmp/nonexistent-cast-test-99999.db" \
    --prompt "debug error crash traceback" \
    --min-confidence 0.1
  assert_success

  result="$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('agent'))
")"
  [ "$result" = "None" ]
}

@test "cast-memory-router: prompt with fewer than 3 tokens returns null agent" {
  sqlite3 "$TEST_DB" "INSERT INTO agent_memories (agent, type, name, description, content, created_at) VALUES ('debugger', 'feedback', 'debug-pattern', 'desc', 'debug error crash', '2026-03-27T00:00:00Z');"

  run python3 "$MEMORY_ROUTER" \
    --db "$TEST_DB" \
    --prompt "debug" \
    --min-confidence 0.1
  assert_success

  result="$(echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('agent'))
")"
  [ "$result" = "None" ]
}

@test "cast-memory-router: always exits 0 even on unexpected input" {
  run python3 "$MEMORY_ROUTER" \
    --db "$TEST_DB" \
    --prompt "" \
    --min-confidence 0.1
  assert_success
  # Must be valid JSON
  echo "$output" | python3 -c "import json, sys; json.load(sys.stdin)"
}
