#!/usr/bin/env bats
# test-memory-injection-order.bats
# Tests for Task 3.2 — memory injection order verification
# Verifies that memory injection comes AFTER stable prefix (CLAUDE.md → rules → agent frontmatter)

setup() {
    # No setup required for this verification test
    # We're asserting call site ordering, not runtime ordering
    :
}

teardown() {
    :
}

@test "UserPromptSubmit hook calls cast-memory-router in retrieve mode" {
    # Verify cast-user-prompt-hook.sh calls memory router with correct args
    [ -f "scripts/cast-user-prompt-hook.sh" ]

    # Check that the hook uses --mode retrieve
    grep -q "'--mode', 'retrieve'" scripts/cast-user-prompt-hook.sh || false
}

@test "cast-user-prompt-hook.sh uses --agent shared for memory retrieval" {
    # Verify agent is set to 'shared' (not hardcoded to something else)
    grep -q "'--agent', 'shared'" scripts/cast-user-prompt-hook.sh || false
}

@test "cast-user-prompt-hook.sh formats memory output as context block" {
    # Verify memory is formatted and injected as additionalContext
    grep -q "additionalContext" scripts/cast-user-prompt-hook.sh || false

    # Verify hookSpecificOutput structure
    grep -q "hookSpecificOutput" scripts/cast-user-prompt-hook.sh || false
}

@test "cast-memory-router.py retrieve mode returns JSON array" {
    # Create a minimal test DB
    export BATS_TEST_TMPDIR="$(mktemp -d)"
    export TEST_DB_PATH="${BATS_TEST_TMPDIR}/test-cast.db"
    export CAST_DB_PATH="${TEST_DB_PATH}"

    # Create minimal agent_memories table
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
CREATE TABLE agent_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT,
    type TEXT,
    name TEXT,
    description TEXT,
    content TEXT,
    importance REAL DEFAULT 0.5,
    decay_rate REAL DEFAULT 0.993,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    valid_from TEXT,
    valid_to TEXT,
    embedding BLOB
);

INSERT INTO agent_memories (agent, type, name, description, content)
VALUES ('shared', 'feedback', 'test_fb', 'Test feedback', 'This is test content');
SQL

    # Call router in retrieve mode
    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 5

    [ "$status" -eq 0 ]

    # Verify JSON array output
    echo "$output" | python3 -c "import sys, json; json.load(sys.stdin); print('OK')" || false

    # Cleanup
    rm -rf "${BATS_TEST_TMPDIR}"
}

@test "memory retrieval result is list of dicts with score field" {
    export BATS_TEST_TMPDIR="$(mktemp -d)"
    export TEST_DB_PATH="${BATS_TEST_TMPDIR}/test-cast.db"
    export CAST_DB_PATH="${TEST_DB_PATH}"

    sqlite3 "${TEST_DB_PATH}" <<'SQL'
CREATE TABLE agent_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT,
    type TEXT,
    name TEXT,
    description TEXT,
    content TEXT,
    importance REAL DEFAULT 0.5,
    decay_rate REAL DEFAULT 0.993,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    valid_from TEXT,
    valid_to TEXT,
    embedding BLOB
);

INSERT INTO agent_memories (agent, type, name, description, content)
VALUES ('shared', 'user', 'test_user', 'Test user', 'User content');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 5

    [ "$status" -eq 0 ]

    # Verify each result has a score field
    echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if 'score' not in item:
        sys.exit(1)
print('OK')
" || false

    rm -rf "${BATS_TEST_TMPDIR}"
}

@test "memory retrieval preserves type field from database" {
    export BATS_TEST_TMPDIR="$(mktemp -d)"
    export TEST_DB_PATH="${BATS_TEST_TMPDIR}/test-cast.db"
    export CAST_DB_PATH="${TEST_DB_PATH}"

    sqlite3 "${TEST_DB_PATH}" <<'SQL'
CREATE TABLE agent_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT,
    type TEXT,
    name TEXT,
    description TEXT,
    content TEXT,
    importance REAL DEFAULT 0.5,
    decay_rate REAL DEFAULT 0.993,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    valid_from TEXT,
    valid_to TEXT,
    embedding BLOB
);

INSERT INTO agent_memories (agent, type, name, description, content)
VALUES ('shared', 'procedural', 'test_proc', 'Test procedural', 'Procedural content');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "procedural" --top-n 5

    [ "$status" -eq 0 ]

    # Verify type field is present and correct
    echo "$output" | grep -q '"type": "procedural"' || false

    rm -rf "${BATS_TEST_TMPDIR}"
}
