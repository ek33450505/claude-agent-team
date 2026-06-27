#!/usr/bin/env bats
# test_cast_memory_persistence.bats — Tests for CAST Memory Persistence
#
# Coverage (surviving tests after orphan script cleanup):
#   1. cast-memory-router.py --mode route returns JSON with agent field (backward compat)
#   2. cast-memory-router.py --mode route returns valid JSON even with no match
#   3. cast-memory-router.py route mode: backward compat via stdin

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ROUTER_SCRIPT="$REPO_DIR/scripts/cast-memory-router.py"

# Use a temp DB for all tests — never touch real cast.db
TEST_DB="/tmp/test_cast_memory_$$.db"

setup() {
    export CAST_DB_PATH="$TEST_DB"
    # Skip all tests if SQLite FTS5 module is not available (e.g. CI macOS runners)
    if ! sqlite3 ":memory:" "CREATE VIRTUAL TABLE t USING fts5(x);" 2>/dev/null; then
        skip "FTS5 module not available"
    fi
    # Initialize a minimal agent_memories table with importance + decay_rate
    sqlite3 "$TEST_DB" "
        CREATE TABLE IF NOT EXISTS agent_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT NOT NULL,
            project TEXT,
            type TEXT NOT NULL DEFAULT 'project',
            name TEXT NOT NULL,
            description TEXT,
            content TEXT,
            importance FLOAT DEFAULT 0.5,
            decay_rate FLOAT DEFAULT 0.995,
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now'))
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts
            USING fts5(name, description, content, content=agent_memories, content_rowid=id);
        INSERT INTO agent_memories (agent, type, name, description, content)
        VALUES ('debugger', 'feedback', 'bats-debug', 'BATS debugging tips',
                'Use bats --tap for TAP output. BATS whitespace issues with wc are common.');
        INSERT INTO agent_memories (agent, type, name, description, content)
        VALUES ('planner', 'user', 'planner-profile', 'Planner agent profile',
                'Plans tasks and creates manifests for orchestrator dispatch.');
        INSERT INTO agent_memories_fts(rowid, name, description, content)
            SELECT id, name, description, content FROM agent_memories;
    "
}

teardown() {
    rm -f "$TEST_DB"
    rm -f "${TEST_DB}-wal"
    rm -f "${TEST_DB}-shm"
}

# ---------------------------------------------------------------------------
# Router route mode backward compatibility
# ---------------------------------------------------------------------------

@test "cast-memory-router --mode route: returns JSON with agent field" {
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
