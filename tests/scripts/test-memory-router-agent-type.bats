#!/usr/bin/env bats
# test-memory-router-agent-type.bats
# Tests for Task 3.3 — memory router --agent-type filtering
# Verifies that lightweight agents (commit, push, merge, code-reviewer) exclude project/reference types

setup() {
    export BATS_TEST_TMPDIR="$(mktemp -d)"
    export TEST_DB_PATH="${BATS_TEST_TMPDIR}/test-cast.db"
    export CAST_DB_PATH="${TEST_DB_PATH}"

    # Create a minimal test database with agent_memories table
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT NOT NULL,
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
SQL
}

teardown() {
    rm -rf "${BATS_TEST_TMPDIR}"
}

@test "retrieve with --agent-type=commit excludes project type" {
    # Insert test memories
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'feedback', 'test_feedback', 'A feedback memory', 'This is feedback memory'),
    ('shared', 'user', 'test_user', 'A user memory', 'This is a user memory'),
    ('shared', 'reference', 'test_ref', 'A reference memory', 'This is a reference memory');
SQL

    # Run with --agent-type=commit (should filter out project and reference)
    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "feedback user" --top-n 10 --agent-type commit

    [ "$status" -eq 0 ]

    # Parse output as JSON and check types
    output_json="$output"

    # feedback should be present
    echo "$output_json" | grep -q '"type": "feedback"'

    # user should be present
    echo "$output_json" | grep -q '"type": "user"'

    # project should NOT be present
    ! echo "$output_json" | grep -q '"type": "project"'

    # reference should NOT be present
    ! echo "$output_json" | grep -q '"type": "reference"'
}

@test "retrieve with --agent-type=push excludes project and reference" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'feedback', 'test_feedback', 'A feedback memory', 'This is feedback memory');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 10 --agent-type push

    [ "$status" -eq 0 ]

    # feedback should be present
    echo "$output" | grep -q '"type": "feedback"'

    # project should NOT be present
    ! echo "$output" | grep -q '"type": "project"'
}

@test "retrieve with --agent-type=merge filters correctly" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'reference', 'test_ref', 'A reference', 'This is a reference'),
    ('shared', 'feedback', 'test_feedback', 'A feedback memory', 'This is feedback');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test feedback" --top-n 10 --agent-type merge

    [ "$status" -eq 0 ]

    # feedback should be present
    echo "$output" | grep -q '"type": "feedback"' || false

    # reference should NOT be present
    ! echo "$output" | grep -q '"type": "reference"' || false
}

@test "retrieve with --agent-type=code-reviewer filters correctly" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'user', 'test_user', 'A user memory', 'This is a user memory');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 10 --agent-type code-reviewer

    [ "$status" -eq 0 ]

    # user should be present
    echo "$output" | grep -q '"type": "user"' || false

    # project should NOT be present
    ! echo "$output" | grep -q '"type": "project"' || false
}

@test "retrieve without --agent-type returns all types" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'reference', 'test_ref', 'A reference memory', 'This is a reference memory'),
    ('shared', 'feedback', 'test_feedback', 'A feedback memory', 'This is feedback memory'),
    ('shared', 'user', 'test_user', 'A user memory', 'This is a user memory');
SQL

    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 10

    [ "$status" -eq 0 ]

    # All types should be present
    echo "$output" | grep -q '"type": "project"' || false
    echo "$output" | grep -q '"type": "reference"' || false
    echo "$output" | grep -q '"type": "feedback"' || false
    echo "$output" | grep -q '"type": "user"' || false
}

@test "retrieve with --agent-type=code-writer (non-haiku) returns all types" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'reference', 'test_ref', 'A reference memory', 'This is a reference memory');
SQL

    # code-writer is not in the lightweight agents list, so should return all
    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 10 --agent-type code-writer

    [ "$status" -eq 0 ]

    # project should be present
    echo "$output" | grep -q '"type": "project"' || false

    # reference should be present
    echo "$output" | grep -q '"type": "reference"' || false
}

@test "--agent-type with explicit --type filter uses explicit filter" {
    sqlite3 "${TEST_DB_PATH}" <<'SQL'
INSERT INTO agent_memories (agent, type, name, description, content) VALUES
    ('shared', 'project', 'test_project', 'A project memory', 'This is a project memory'),
    ('shared', 'feedback', 'test_feedback', 'A feedback memory', 'This is feedback memory');
SQL

    # When both --type and --agent-type are provided, explicit --type should take precedence
    run python3 scripts/cast-memory-router.py --mode retrieve --agent shared \
        --prompt "test" --top-n 10 --agent-type commit --type project

    [ "$status" -eq 0 ]

    # Only project should be present (explicit --type overrides agent-type filtering)
    echo "$output" | grep -q '"type": "project"' || false

    # feedback should NOT be present
    ! echo "$output" | grep -q '"type": "feedback"' || false
}
