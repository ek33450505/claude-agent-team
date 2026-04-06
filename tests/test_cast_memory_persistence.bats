#!/usr/bin/env bats
# test_cast_memory_persistence.bats — Tests for CAST Memory Persistence Tier 1
#
# Coverage:
#   1. cast-memory-fts5-migrate.py runs without error and is idempotent
#   2. cast-memory-schema-v2.py adds importance + decay_rate columns + backfills
#   3. cast-memory-router.py --mode retrieve returns JSON array
#   4. cast-memory-router.py --mode route returns JSON with agent field (backward compat)
#   5. cast-memory-seed-procedural.py seeds 5 rows with type=procedural, agent=shared
#   6. FTS5 search finds a seeded memory by keyword

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FTS5_SCRIPT="$REPO_DIR/scripts/cast-memory-fts5-migrate.py"
SCHEMA_SCRIPT="$REPO_DIR/scripts/cast-memory-schema-v2.py"
ROUTER_SCRIPT="$REPO_DIR/scripts/cast-memory-router.py"
SEED_SCRIPT="$REPO_DIR/scripts/cast-memory-seed-procedural.py"

# Use a temp DB for all tests — never touch real cast.db
TEST_DB="/tmp/test_cast_memory_$$.db"

setup() {
    export CAST_DB_PATH="$TEST_DB"
    # Initialize a minimal agent_memories table
    sqlite3 "$TEST_DB" "
        CREATE TABLE IF NOT EXISTS agent_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT NOT NULL,
            project TEXT,
            type TEXT NOT NULL DEFAULT 'project',
            name TEXT NOT NULL,
            description TEXT,
            content TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        INSERT INTO agent_memories (agent, type, name, description, content)
        VALUES ('debugger', 'feedback', 'bats-debug', 'BATS debugging tips',
                'Use bats --tap for TAP output. BATS whitespace issues with wc are common.');
        INSERT INTO agent_memories (agent, type, name, description, content)
        VALUES ('planner', 'user', 'planner-profile', 'Planner agent profile',
                'Plans tasks and creates manifests for orchestrator dispatch.');
    "
}

teardown() {
    rm -f "$TEST_DB"
    rm -f "${TEST_DB}-wal"
    rm -f "${TEST_DB}-shm"
}

# ---------------------------------------------------------------------------
# Test 1: FTS5 migration runs cleanly on fresh DB
# ---------------------------------------------------------------------------

@test "cast-memory-fts5-migrate: exits 0 and reports rows indexed" {
    run python3 "$FTS5_SCRIPT"
    assert_success
    assert_output --partial "rows indexed"
}

@test "cast-memory-fts5-migrate: is idempotent (safe to run twice)" {
    python3 "$FTS5_SCRIPT"
    run python3 "$FTS5_SCRIPT"
    assert_success
    assert_output --partial "already present"
}

@test "cast-memory-fts5-migrate: creates agent_memories_fts table" {
    python3 "$FTS5_SCRIPT"
    result=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'")
    [ "$result" = "agent_memories_fts" ]
}

@test "cast-memory-fts5-migrate: creates all three sync triggers" {
    python3 "$FTS5_SCRIPT"
    for trigger in am_ai am_au am_ad; do
        result=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='trigger' AND name='$trigger'")
        [ "$result" = "$trigger" ]
    done
}

# ---------------------------------------------------------------------------
# Test 2: Schema migration adds columns and backfills
# ---------------------------------------------------------------------------

@test "cast-memory-schema-v2: exits 0 and reports columns added" {
    run python3 "$SCHEMA_SCRIPT"
    assert_success
    assert_output --partial "Added importance column"
    assert_output --partial "Added decay_rate column"
}

@test "cast-memory-schema-v2: importance column exists with FLOAT type" {
    python3 "$SCHEMA_SCRIPT"
    result=$(sqlite3 "$TEST_DB" "PRAGMA table_info(agent_memories)" | grep importance | awk -F'|' '{print $3}')
    [ "$result" = "FLOAT" ]
}

@test "cast-memory-schema-v2: decay_rate column exists with FLOAT type" {
    python3 "$SCHEMA_SCRIPT"
    result=$(sqlite3 "$TEST_DB" "PRAGMA table_info(agent_memories)" | grep decay_rate | awk -F'|' '{print $3}')
    [ "$result" = "FLOAT" ]
}

@test "cast-memory-schema-v2: backfills feedback/user rows with decay_rate=0.999" {
    python3 "$SCHEMA_SCRIPT"
    count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type IN ('feedback','user') AND decay_rate = 0.999" | tr -d ' ')
    [ "$count" -ge "1" ]
}

@test "cast-memory-schema-v2: is idempotent (safe to run twice)" {
    python3 "$SCHEMA_SCRIPT"
    run python3 "$SCHEMA_SCRIPT"
    assert_success
    assert_output --partial "already present"
}

# ---------------------------------------------------------------------------
# Test 3: Router retrieve mode returns JSON array
# ---------------------------------------------------------------------------

@test "cast-memory-router --mode retrieve: returns valid JSON array" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    run python3 "$ROUTER_SCRIPT" --mode retrieve --agent debugger --prompt "BATS whitespace wc" --top-n 3
    assert_success
    # Output should start with [ (JSON array)
    [[ "$output" == \[* ]]
}

@test "cast-memory-router --mode retrieve: returns at most top-n results" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    output=$(python3 "$ROUTER_SCRIPT" --mode retrieve --agent debugger --prompt "debugging" --top-n 1)
    # Count objects in JSON array — should be <= 1
    count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")
    [ "$count" -le "1" ]
}

# ---------------------------------------------------------------------------
# Test 4: Router route mode backward compatibility
# ---------------------------------------------------------------------------

@test "cast-memory-router --mode route: returns JSON with agent field" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    run python3 "$ROUTER_SCRIPT" --prompt "debugging BATS test failure"
    assert_success
    # Should contain agent field
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'agent' in d"
}

@test "cast-memory-router --mode route: returns valid JSON even with no match" {
    run python3 "$ROUTER_SCRIPT" --prompt "xyz quantum flux capacitor"
    assert_success
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'agent' in d"
}

@test "cast-memory-router route mode: backward compat via stdin" {
    run bash -c "echo 'BATS debugging test failure wc output' | python3 '$ROUTER_SCRIPT'"
    assert_success
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'agent' in d"
}

# ---------------------------------------------------------------------------
# Test 5: Seed script inserts procedural memories
# ---------------------------------------------------------------------------

@test "cast-memory-seed-procedural: exits 0" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    run python3 "$SEED_SCRIPT"
    assert_success
}

@test "cast-memory-seed-procedural: seeds exactly 5 memories" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type='procedural'" | tr -d ' ')
    [ "$count" -eq "5" ]
}

@test "cast-memory-seed-procedural: all memories have agent=shared" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    non_shared=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type='procedural' AND agent != 'shared'" | tr -d ' ')
    [ "$non_shared" -eq "0" ]
}

@test "cast-memory-seed-procedural: is idempotent (second run reports already present)" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    run python3 "$SEED_SCRIPT"
    assert_success
    assert_output --partial "already present"
}

@test "cast-memory-seed-procedural: bats-wc-whitespace memory has importance=0.9" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    importance=$(sqlite3 "$TEST_DB" "SELECT importance FROM agent_memories WHERE name='bats-wc-whitespace'" | tr -d ' ')
    [ "$importance" = "0.9" ]
}

# ---------------------------------------------------------------------------
# Test 6: FTS5 search finds seeded memory by keyword
# ---------------------------------------------------------------------------

@test "FTS5 search: finds memory matching 'whitespace' keyword" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    # Rebuild FTS index to include newly seeded rows
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    # Use Python's sqlite3 (has FTS5) instead of sqlite3 CLI (may lack FTS5 on CI)
    result=$(python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['CAST_DB_PATH'])
row = conn.execute(\"SELECT content FROM agent_memories_fts WHERE agent_memories_fts MATCH 'whitespace' LIMIT 1\").fetchone()
print(row[0] if row else '')
conn.close()
")
    [ -n "$result" ]
}

@test "FTS5 search: retrieve mode finds seeded memory by keyword" {
    python3 "$SCHEMA_SCRIPT" >/dev/null 2>&1
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    python3 "$SEED_SCRIPT" >/dev/null 2>&1
    python3 "$FTS5_SCRIPT" >/dev/null 2>&1
    output=$(python3 "$ROUTER_SCRIPT" --mode retrieve --agent debugger --prompt "sandbox push dangerouslyDisableSandbox" --top-n 5)
    count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")
    [ "$count" -ge "1" ]
}
