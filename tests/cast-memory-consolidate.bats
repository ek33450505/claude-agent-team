#!/usr/bin/env bats
# cast-memory-consolidate.bats — Tests for scripts/cast-memory-consolidate.py
#
# Isolation: uses setup_temp_home/teardown_temp_home (HOME redirected to tmp).
# DB:        temp cast.db created per test with only the tables each test needs.
#
# Note on BATS `run` and stderr: BATS `run` captures both stdout and stderr into
# $output. run_consolidate redirects stderr to /dev/null so $output contains only
# the JSON. Tests that specifically need to check a stderr WARNING use
# run_with_stderr which merges stderr into $output via 2>&1.
#
# Coverage:
#   (a) missing DB / missing table  → exit 1 with error to stderr
#   (b) valid empty DB              → exit 0, JSON with required fields, all zero counts
#   (c) --dry-run                   → exit 0, correct counts reported, no DB mutations
#   (d) op_decay                    → importance scores reduced for old rows
#   (e) op_deduplicate              → no-embedding column path skips gracefully
#   (f) op_archive                  → low-importance rows moved; missing table warned
#   (g) op_promote                  → retrieval_count >= 5 bumps importance; missing col skips
#   (h) JSON output shape           → timestamp present, all required keys

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-memory-consolidate.py"

# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

# Create agent_memories + archived_memories with full schemas.
# Use CURRENT_TIMESTAMP (a recognised SQLite constant) not datetime() expression
# in DEFAULT clauses — SQLite rejects non-constant DEFAULT expressions in older builds.
init_db() {
  sqlite3 "$CAST_DB_PATH" 'CREATE TABLE IF NOT EXISTS agent_memories (
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
  CREATE TABLE IF NOT EXISTS archived_memories (
    id                INTEGER PRIMARY KEY,
    agent             TEXT,
    project           TEXT,
    type              TEXT,
    name              TEXT,
    description       TEXT,
    content           TEXT,
    created_at        TEXT,
    updated_at        TEXT,
    confidence        REAL,
    importance        REAL,
    decay_rate        REAL,
    valid_from        TEXT,
    valid_to          TEXT,
    embedding         BLOB,
    last_validated_at TEXT,
    retrieval_count   INTEGER,
    archived_at       TEXT DEFAULT CURRENT_TIMESTAMP
  );'
}

# Create only agent_memories — used by archive tests that need archived_memories absent.
init_agent_memories_only() {
  sqlite3 "$CAST_DB_PATH" 'CREATE TABLE IF NOT EXISTS agent_memories (
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
  );'
}

# Insert a minimal agent_memories row with controlled updated_at / importance.
# $1=name  $2=importance  $3=decay_rate  $4=updated_at (ISO8601, default=now)
insert_memory() {
  local name="$1"
  local importance="$2"
  local decay_rate="${3:-0.995}"
  local updated_at="${4:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories
       (agent, project, type, name, content, importance, decay_rate, updated_at, created_at)
     VALUES
       ('test-agent', 'test-proj', 'project', '$name', 'test content',
        $importance, $decay_rate, '$updated_at', '$updated_at');"
}

# Insert a row with retrieval_count set.
# $1=name  $2=importance  $3=retrieval_count
insert_memory_with_rc() {
  local name="$1"
  local importance="$2"
  local rc="$3"
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories
       (agent, project, type, name, content, importance, decay_rate,
        retrieval_count, updated_at, created_at)
     VALUES
       ('test-agent', 'test-proj', 'project', '$name', 'test content',
        $importance, 0.995, $rc, '$now', '$now');"
}

# Query helper.
db_query() {
  sqlite3 "$CAST_DB_PATH" "$1"
}

# Run script with stderr suppressed (stderr WARNING must not pollute $output JSON).
run_consolidate() {
  run bash -c "python3 '$SCRIPT' --db '$CAST_DB_PATH' 2>/dev/null"
}

run_consolidate_dry() {
  run bash -c "python3 '$SCRIPT' --db '$CAST_DB_PATH' --dry-run 2>/dev/null"
}

# Run script merging stderr into $output (for tests that assert on WARNING text).
run_with_stderr() {
  run bash -c "python3 '$SCRIPT' --db '$CAST_DB_PATH' 2>&1"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/logs"
  export CAST_DB_PATH="$HOME/.claude/cast.db"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# (a) Missing DB / missing table → exit 1
# ---------------------------------------------------------------------------

@test "(a) missing DB file exits 1 with error on stderr" {
  run bash -c "python3 '$SCRIPT' --db '$HOME/.claude/does-not-exist.db' 2>&1"
  assert_failure
  assert_output --partial "ERROR"
}

@test "(a) existing DB but missing agent_memories table exits 1" {
  sqlite3 "$CAST_DB_PATH" "SELECT 1;" >/dev/null 2>&1
  run bash -c "python3 '$SCRIPT' --db '$CAST_DB_PATH' 2>&1"
  assert_failure
  assert_output --partial "ERROR"
}

@test "(a) exit code is 1 when agent_memories absent" {
  sqlite3 "$CAST_DB_PATH" "SELECT 1;" >/dev/null 2>&1
  run bash -c "python3 '$SCRIPT' --db '$CAST_DB_PATH' 2>/dev/null"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (b) Valid empty DB → exit 0, zero counts, valid JSON
# ---------------------------------------------------------------------------

@test "(b) empty agent_memories table exits 0" {
  init_db
  run_consolidate
  assert_success
}

@test "(b) empty DB: output is valid JSON" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -m json.tool > /dev/null
}

@test "(b) empty DB: all operation counts are 0" {
  init_db
  run_consolidate
  assert_success
  local decayed merged archived promoted
  decayed="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["decayed"])')"
  merged="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["merged"])')"
  archived="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["archived"])')"
  promoted="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["promoted"])')"
  [ "$decayed" -eq 0 ]
  [ "$merged" -eq 0 ]
  [ "$archived" -eq 0 ]
  [ "$promoted" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (c) --dry-run → counts reported, no DB mutations
# ---------------------------------------------------------------------------

@test "(c) --dry-run exits 0" {
  init_db
  insert_memory "dry-run-mem" "0.05" "0.995" "2020-01-01T00:00:00Z"
  run_consolidate_dry
  assert_success
}

@test "(c) --dry-run output is valid JSON" {
  init_db
  insert_memory "dry-run-mem2" "0.05" "0.995" "2020-01-01T00:00:00Z"
  run_consolidate_dry
  assert_success
  printf '%s' "$output" | python3 -m json.tool > /dev/null
}

@test "(c) --dry-run does not mutate importance in DB" {
  init_db
  insert_memory "nodecay-dry" "0.8" "0.995" "2020-01-01T00:00:00Z"

  local before; before="$(db_query "SELECT importance FROM agent_memories WHERE name='nodecay-dry';")"
  run_consolidate_dry
  assert_success
  local after; after="$(db_query "SELECT importance FROM agent_memories WHERE name='nodecay-dry';")"
  [ "$before" = "$after" ]
}

@test "(c) --dry-run does not remove low-importance rows from agent_memories" {
  init_db
  insert_memory "archive-dry" "0.05" "0.0"

  run_consolidate_dry
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='archive-dry';")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (d) op_decay — old rows get importance reduced
# ---------------------------------------------------------------------------

@test "(d) decay: old row importance is reduced after real run" {
  init_db
  # decay_rate=0.1 (not the default 0.995) keeps importance well above 0.1 even
  # for a 2-year-old row, so op_archive never removes it from agent_memories.
  # Formula: 0.8 * exp(-0.1 * 17520 / 8760) ≈ 0.655 — clearly decayed, clearly > 0.1.
  insert_memory "decay-old" "0.8" "0.1" "2024-01-01T00:00:00Z"

  local before; before="$(db_query "SELECT importance FROM agent_memories WHERE name='decay-old';")"
  run_consolidate
  assert_success
  local after; after="$(db_query "SELECT importance FROM agent_memories WHERE name='decay-old';")"
  python3 -c "import sys; b=float('$before'); a=float('$after'); sys.exit(0 if a < b else 1)"
}

@test "(d) decay: decayed count in JSON >= 1 when old rows present" {
  init_db
  insert_memory "decay-count-check" "0.8" "0.995" "2024-01-01T00:00:00Z"

  run_consolidate
  assert_success
  local decayed; decayed="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["decayed"])')"
  [ "$decayed" -ge 1 ]
}

@test "(d) decay: row with NULL updated_at is skipped gracefully (no crash)" {
  init_db
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, content, importance, decay_rate, updated_at)
     VALUES ('test-agent', 'project', 'null-updated-at', 'content', 0.8, 0.995, NULL);"

  run_consolidate
  assert_success
}

@test "(d) decay: row with NULL importance treated as 0.5 baseline (no crash)" {
  init_db
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, content, importance, decay_rate, updated_at)
     VALUES ('test-agent', 'project', 'null-importance', 'content', NULL, 0.995, '2024-01-01T00:00:00Z');"

  run_consolidate
  assert_success
}

# ---------------------------------------------------------------------------
# (e) op_deduplicate — no embedding column path is handled
# ---------------------------------------------------------------------------

@test "(e) deduplicate: missing embedding column → merged=0, no crash" {
  # Create a table with all decay columns but no embedding column
  sqlite3 "$CAST_DB_PATH" 'CREATE TABLE agent_memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    type TEXT, name TEXT, content TEXT,
    importance REAL DEFAULT 0.5, decay_rate REAL DEFAULT 0.0,
    updated_at TEXT, retrieval_count INTEGER DEFAULT 0
  );
  CREATE TABLE archived_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT, type TEXT, name TEXT, content TEXT,
    importance REAL, decay_rate REAL, updated_at TEXT,
    retrieval_count INTEGER, archived_at TEXT DEFAULT CURRENT_TIMESTAMP
  );'
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, content, importance, decay_rate, updated_at)
     VALUES ('agent-a', 'project', 'mem-no-embed', 'content', 0.8, 0.0, '$now');"

  run_consolidate
  assert_success
  local merged; merged="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["merged"])')"
  [ "$merged" -eq 0 ]
}

@test "(e) deduplicate: rows with NULL embedding are skipped, no crash" {
  init_db
  insert_memory "embed-null-a" "0.8" "0.0"
  insert_memory "embed-null-b" "0.6" "0.0"

  run_consolidate
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories;")"
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# (f) op_archive — low-importance rows moved; missing archived_memories warned
# ---------------------------------------------------------------------------

@test "(f) archive: row with importance < 0.1 is removed from agent_memories" {
  init_db
  insert_memory "low-importance-mem" "0.05" "0.0"

  run_consolidate
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='low-importance-mem';")"
  [ "$count" -eq 0 ]
}

@test "(f) archive: archived row is present in archived_memories table" {
  init_db
  insert_memory "archive-target" "0.05" "0.0"

  run_consolidate
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM archived_memories WHERE name='archive-target';")"
  [ "$count" -eq 1 ]
}

@test "(f) archive: row with importance >= 0.1 is NOT archived" {
  init_db
  insert_memory "keep-this-mem" "0.5" "0.0"

  run_consolidate
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='keep-this-mem';")"
  [ "$count" -eq 1 ]
}

@test "(f) archive: missing archived_memories table → WARNING on stderr, archived=0, exit 0" {
  # Only agent_memories — no archived_memories table
  init_agent_memories_only
  insert_memory "archive-no-table" "0.05" "0.0"

  # Capture stderr so we can assert WARNING text
  run_with_stderr
  assert_success
  assert_output --partial "WARNING"

  # Agent_memories row must still be present (archive was skipped)
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='archive-no-table';")"
  [ "$count" -eq 1 ]
}

@test "(f) archive: archived count in JSON matches rows moved" {
  init_db
  insert_memory "archive-count-a" "0.05" "0.0"
  insert_memory "archive-count-b" "0.04" "0.0"
  insert_memory "archive-count-c" "0.8" "0.0"

  run_consolidate
  assert_success
  local archived; archived="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["archived"])')"
  [ "$archived" -eq 2 ]
}

@test "(f) archive: boundary importance=0.1 is NOT archived (threshold is < 0.1)" {
  init_db
  insert_memory "boundary-0-1" "0.1" "0.0"

  run_consolidate
  assert_success
  local count; count="$(db_query "SELECT COUNT(*) FROM agent_memories WHERE name='boundary-0-1';")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# (g) op_promote — retrieval_count >= 5 bumps importance
# ---------------------------------------------------------------------------

@test "(g) promote: retrieval_count >= 5 increases importance by 0.1" {
  init_db
  insert_memory_with_rc "high-retrieval" "0.5" "7"

  run_consolidate
  assert_success
  local imp; imp="$(db_query "SELECT importance FROM agent_memories WHERE name='high-retrieval';")"
  python3 -c "import sys; v=float('$imp'); sys.exit(0 if v == 0.6 else 1)"
}

@test "(g) promote: importance is capped at 1.0 after bump" {
  init_db
  insert_memory_with_rc "near-max-retrieval" "0.95" "5"

  run_consolidate
  assert_success
  local imp; imp="$(db_query "SELECT importance FROM agent_memories WHERE name='near-max-retrieval';")"
  python3 -c "import sys; v=float('$imp'); sys.exit(0 if v == 1.0 else 1)"
}

@test "(g) promote: retrieval_count reset to 0 after promotion" {
  init_db
  insert_memory_with_rc "reset-rc" "0.5" "6"

  run_consolidate
  assert_success
  local rc; rc="$(db_query "SELECT retrieval_count FROM agent_memories WHERE name='reset-rc';")"
  [ "$rc" -eq 0 ]
}

@test "(g) promote: row with retrieval_count < 5 is NOT promoted" {
  init_db
  insert_memory_with_rc "low-retrieval" "0.5" "4"

  run_consolidate
  assert_success
  local imp; imp="$(db_query "SELECT importance FROM agent_memories WHERE name='low-retrieval';")"
  python3 -c "import sys; v=float('$imp'); sys.exit(0 if v == 0.5 else 1)"
}

@test "(g) promote: boundary retrieval_count=5 is promoted (>= threshold)" {
  init_db
  insert_memory_with_rc "exactly-5-rc" "0.5" "5"

  run_consolidate
  assert_success
  local imp; imp="$(db_query "SELECT importance FROM agent_memories WHERE name='exactly-5-rc';")"
  python3 -c "import sys; v=float('$imp'); sys.exit(0 if v == 0.6 else 1)"
}

@test "(g) promote: missing retrieval_count column → promoted=0, no crash" {
  # Create a table with decay columns but WITHOUT retrieval_count.
  # op_decay needs: id, importance, decay_rate, updated_at.
  # op_promote checks column_exists and returns 0 immediately if absent.
  sqlite3 "$CAST_DB_PATH" 'CREATE TABLE agent_memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    type TEXT, name TEXT, content TEXT,
    importance REAL DEFAULT 0.5, decay_rate REAL DEFAULT 0.0,
    updated_at TEXT
  );
  CREATE TABLE archived_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT, type TEXT, name TEXT, content TEXT,
    importance REAL, decay_rate REAL, updated_at TEXT,
    archived_at TEXT DEFAULT CURRENT_TIMESTAMP
  );'
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  sqlite3 "$CAST_DB_PATH" \
    "INSERT INTO agent_memories (agent, type, name, content, importance, decay_rate, updated_at)
     VALUES ('agent-a', 'project', 'no-rc-col', 'content', 0.8, 0.0, '$now');"

  run_consolidate
  assert_success
  local promoted; promoted="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["promoted"])')"
  [ "$promoted" -eq 0 ]
}

@test "(g) promote: promoted count in JSON reflects rows bumped" {
  init_db
  insert_memory_with_rc "promo-a" "0.5" "5"
  insert_memory_with_rc "promo-b" "0.6" "8"
  insert_memory_with_rc "no-promo" "0.5" "2"

  run_consolidate
  assert_success
  local promoted; promoted="$(printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["promoted"])')"
  [ "$promoted" -eq 2 ]
}

# ---------------------------------------------------------------------------
# (h) JSON output shape
# ---------------------------------------------------------------------------

@test "(h) output contains 'decayed' key" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "decayed" in d'
}

@test "(h) output contains 'merged' key" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "merged" in d'
}

@test "(h) output contains 'archived' key" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "archived" in d'
}

@test "(h) output contains 'promoted' key" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "promoted" in d'
}

@test "(h) output contains 'timestamp' key in ISO format" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "timestamp" in d and "T" in d["timestamp"]'
}

@test "(h) all numeric fields are non-negative integers" {
  init_db
  run_consolidate
  assert_success
  printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for key in ("decayed", "merged", "archived", "promoted"):
    v = d[key]
    assert isinstance(v, int) and v >= 0, f"{key}={v!r} is not a non-negative int"
'
}
