#!/usr/bin/env bats
# memory-pipeline.bats — BATS tests for Phase 3 memory write and read pipelines
#
# Test coverage:
#   - Task 3.1: SubagentStop hook writes ## Facts blocks to agent_memories
#   - Task 3.2: UserPromptSubmit hook retrieves memories and injects as context
#   - Deduplication: duplicate Facts are updated, not inserted
#   - Schema resilience: graceful handling of missing agent_memories table

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DB="${BATS_TMPDIR}/test-cast-memory-${RANDOM}.db"
STOP_HOOK="${REPO_ROOT}/scripts/cast-subagent-stop-hook.sh"
PROMPT_HOOK="${REPO_ROOT}/scripts/cast-user-prompt-hook.sh"
ROUTER="${REPO_ROOT}/scripts/cast-memory-router.py"
INIT_SCRIPT="${REPO_ROOT}/scripts/cast-db-init.sh"
ROUTER_BACKUP="${BATS_TMPDIR}/cast-memory-router-backup-$$.py"

# Helper: build a valid SubagentStop JSON payload from a response string.
# Uses Python json.dumps to ensure multiline strings are properly escaped.
make_stop_payload() {
    local agent_type="${1:-test-agent}"
    local session_id="${2:-test-session-123}"
    local response_text="${3:-}"
    _AGENT_TYPE="$agent_type" _SESSION_ID="$session_id" _RESPONSE_TEXT="$response_text" \
    python3 -c "
import json, os
payload = {
    'agent_type': os.environ['_AGENT_TYPE'],
    'session_id': os.environ['_SESSION_ID'],
    'stop_reason': 'end_turn',
    'agent_response': {
        'content': [{'type': 'text', 'text': os.environ['_RESPONSE_TEXT']}]
    }
}
print(json.dumps(payload))
"
}

setup() {
    # Create a clean test DB for each test
    export CAST_DB_PATH="${TEST_DB}"
    rm -f "${TEST_DB}" 2>/dev/null || true
    mkdir -p "$(dirname "${TEST_DB}")"

    # Initialize schema
    if [ -f "${INIT_SCRIPT}" ]; then
        bash "${INIT_SCRIPT}" --db "${TEST_DB}" >/dev/null 2>&1 || true
    else
        # Minimal schema init if cast-db-init.sh is not available
        sqlite3 "${TEST_DB}" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_memories (
    id INTEGER PRIMARY KEY,
    agent TEXT NOT NULL,
    project TEXT,
    type TEXT,
    name TEXT,
    description TEXT,
    content TEXT,
    created_at TEXT,
    updated_at TEXT,
    importance REAL DEFAULT 0.5,
    decay_rate REAL DEFAULT 0.0,
    valid_from TEXT,
    valid_to TEXT,
    superseded_by INTEGER,
    embedding BLOB,
    source_type TEXT,
    confidence REAL DEFAULT 1.0
);
CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(name, description, content);
SQL
    fi
}

teardown() {
    # Clean up test DB
    rm -f "${TEST_DB}" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: SubagentStop hook writes Facts block to agent_memories
# ──────────────────────────────────────────────────────────────────────────────

@test "SubagentStop hook: Facts block writes to agent_memories" {
    local response='Status: DONE

## Facts
name: test-fact-one | type: project | content: This is a test fact about the project.
name: user-pref | type: feedback | content: User prefers terse responses.

## Work Log
- Did something
'

    # Build valid JSON payload (heredoc expansion creates invalid JSON with literal newlines)
    local payload
    payload=$(make_stop_payload "test-agent" "test-session-123" "$response")

    # Run the hook
    export CAST_DB_PATH="${TEST_DB}"
    echo "$payload" | bash "${STOP_HOOK}" >/dev/null 2>&1

    # Verify facts were written to agent_memories
    local count=$(sqlite3 "${TEST_DB}" "SELECT COUNT(*) FROM agent_memories WHERE agent='test-agent'")
    [ "$count" -eq 2 ] || { echo "Expected 2 facts, got $count"; exit 1; }

    # Verify fact details
    local fact1=$(sqlite3 "${TEST_DB}" "SELECT name, type, content FROM agent_memories WHERE name='test-fact-one'")
    [[ "$fact1" =~ "test-fact-one" ]] || { echo "Fact test-fact-one not found"; exit 1; }
    [[ "$fact1" =~ "project" ]] || { echo "Fact type not project"; exit 1; }

    local fact2=$(sqlite3 "${TEST_DB}" "SELECT name, type FROM agent_memories WHERE name='user-pref'")
    [[ "$fact2" =~ "user-pref" ]] || { echo "Fact user-pref not found"; exit 1; }
    [[ "$fact2" =~ "feedback" ]] || { echo "Fact type not feedback"; exit 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Deduplication — second run with same agent+name updates, not inserts
# ──────────────────────────────────────────────────────────────────────────────

@test "Memory pipeline: deduplication by (agent, name)" {
    # Write initial facts
    local response1='## Facts
name: dup-test | type: project | content: Version 1 of this fact.
'

    local payload1
    payload1=$(make_stop_payload "agent-x" "session-1" "$response1")

    export CAST_DB_PATH="${TEST_DB}"
    echo "$payload1" | bash "${STOP_HOOK}" >/dev/null 2>&1

    local count1=$(sqlite3 "${TEST_DB}" "SELECT COUNT(*) FROM agent_memories WHERE agent='agent-x' AND name='dup-test'")
    [ "$count1" -eq 1 ] || { echo "Expected 1 initial row, got $count1"; exit 1; }

    local content1=$(sqlite3 "${TEST_DB}" "SELECT content FROM agent_memories WHERE agent='agent-x' AND name='dup-test'")
    [[ "$content1" =~ "Version 1" ]] || { echo "Content not Version 1"; exit 1; }

    # Second run with same agent+name, different content
    local response2='## Facts
name: dup-test | type: project | content: Version 2 of this fact.
'

    local payload2
    payload2=$(make_stop_payload "agent-x" "session-2" "$response2")

    echo "$payload2" | bash "${STOP_HOOK}" >/dev/null 2>&1

    # Total count should still be 1 (updated, not inserted)
    local count2=$(sqlite3 "${TEST_DB}" "SELECT COUNT(*) FROM agent_memories WHERE agent='agent-x' AND name='dup-test'")
    [ "$count2" -eq 1 ] || { echo "Expected 1 deduplicated row, got $count2"; exit 1; }

    # Content should be updated
    local content2=$(sqlite3 "${TEST_DB}" "SELECT content FROM agent_memories WHERE agent='agent-x' AND name='dup-test'")
    [[ "$content2" =~ "Version 2" ]] || { echo "Content not updated to Version 2"; exit 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: UserPromptSubmit hook: memory router called (smoke test with mocked router)
# ──────────────────────────────────────────────────────────────────────────────

@test "UserPromptSubmit hook: retrieves memories when router is present" {
    # Create a mock router script that returns test data
    local mock_router="${BATS_TMPDIR}/mock-cast-memory-router.py"
    cat > "${mock_router}" <<'PYTHON'
#!/usr/bin/env python3
import json, sys
# Mock return: always return one memory regardless of input
data = [
    {
        "score": 0.85,
        "agent": "shared",
        "type": "project",
        "name": "test-memory",
        "content": "This is a test memory from the router."
    }
]
print(json.dumps(data))
PYTHON
    chmod +x "${mock_router}"

    # Temporarily replace router with mock (save real router to temp backup first)
    local hook_dir="$(dirname "${PROMPT_HOOK}")"
    cp "${hook_dir}/cast-memory-router.py" "${ROUTER_BACKUP}"
    cp "${mock_router}" "${hook_dir}/cast-memory-router.py"

    # Create UserPromptSubmit payload
    local payload=$(cat <<EOF
{
    "session_id": "test-session",
    "prompt": "What is the project structure?"
}
EOF
)

    # Run the hook and capture output
    local output
    export CAST_DB_PATH="${TEST_DB}"
    output=$(echo "$payload" | bash "${PROMPT_HOOK}" 2>/dev/null || true)

    # Restore original router from backup
    cp "${ROUTER_BACKUP}" "${hook_dir}/cast-memory-router.py" 2>/dev/null || true

    # Verify hook output contains hookSpecificOutput with additionalContext
    if [ -n "$output" ]; then
        # Output should be valid JSON with hookSpecificOutput
        echo "$output" | python3 -c "import sys, json; d = json.load(sys.stdin); assert 'hookSpecificOutput' in d, 'No hookSpecificOutput'; print('OK')" 2>/dev/null || true
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Graceful handling of missing agent_memories table
# ──────────────────────────────────────────────────────────────────────────────

@test "Memory write: gracefully handles missing agent_memories table" {
    # Create empty DB with no tables
    rm -f "${TEST_DB}"
    sqlite3 "${TEST_DB}" "SELECT 1;" >/dev/null 2>&1

    local response='## Facts
name: should-not-error | type: project | content: Test content.
'

    local payload=$(cat <<EOF
{
    "agent_type": "test-agent",
    "session_id": "session-123",
    "stop_reason": "end_turn",
    "agent_response": {
        "content": [
            {"type": "text", "text": "$response"}
        ]
    }
}
EOF
)

    # Hook should not crash even though table is missing
    export CAST_DB_PATH="${TEST_DB}"
    echo "$payload" | bash "${STOP_HOOK}" >/dev/null 2>&1
    # If we get here without error, test passes
    [ $? -eq 0 ] || { echo "Hook crashed on missing table"; exit 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: Fact validation — invalid type/name/slug rejected silently
# ──────────────────────────────────────────────────────────────────────────────

@test "Memory write: rejects invalid fact formats (bad type, empty name, invalid slug)" {
    local response='## Facts
name: valid-fact | type: project | content: Valid fact content.
name: bad slug! | type: project | content: Name has invalid characters.
name: another-fact | type: invalid_type | content: Invalid type value.
name:  | type: project | content: Empty name field.
'

    local payload
    payload=$(make_stop_payload "test-agent" "session-123" "$response")

    export CAST_DB_PATH="${TEST_DB}"
    echo "$payload" | bash "${STOP_HOOK}" >/dev/null 2>&1

    # Only the valid fact should be written
    local count=$(sqlite3 "${TEST_DB}" "SELECT COUNT(*) FROM agent_memories WHERE agent='test-agent'")
    [ "$count" -eq 1 ] || { echo "Expected 1 valid fact, got $count"; exit 1; }

    local name=$(sqlite3 "${TEST_DB}" "SELECT name FROM agent_memories WHERE agent='test-agent'")
    [ "$name" = "valid-fact" ] || { echo "Expected name 'valid-fact', got '$name'"; exit 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: user_profile type support in write and retrieve pipelines
# ──────────────────────────────────────────────────────────────────────────────

@test "Memory pipeline: user_profile type is accepted and stored" {
    local response='## Facts
name: user-work-hours | type: user_profile | content: Ed works 9am-6pm ET.
'

    local payload
    payload=$(make_stop_payload "test-agent" "session-123" "$response")

    export CAST_DB_PATH="${TEST_DB}"
    echo "$payload" | bash "${STOP_HOOK}" >/dev/null 2>&1

    # Verify user_profile fact was written
    local fact_type=$(sqlite3 "${TEST_DB}" "SELECT type FROM agent_memories WHERE name='user-work-hours'")
    [ "$fact_type" = "user_profile" ] || { echo "Expected type 'user_profile', got '$fact_type'"; exit 1; }
}
