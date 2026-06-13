#!/usr/bin/env bats
# cast-stop-failure-hook.bats
# Regression tests for cast-stop-failure-hook.sh
#
# Covers:
#   (1) Benign invalid_request with unknown agent must NOT write an event file
#   (2) Real failure with identifiable agent MUST write an event file
#   (3) agent_type field is correctly used to identify the agent

bats_require_minimum_version 1.5.0

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$REPO_DIR/scripts/cast-stop-failure-hook.sh"

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    FAKE_HOME="${TMPDIR_TEST}/home"
    mkdir -p "${FAKE_HOME}/.claude/cast/events"
    mkdir -p "${FAKE_HOME}/.claude/logs"
    export BATS_FAKE_HOME="$FAKE_HOME"
    export BATS_EVENTS_DIR="${FAKE_HOME}/.claude/cast/events"

    # Stub notification binaries so tests never fire real desktop alerts.
    # The stub dir lives under $TMPDIR_TEST; the existing teardown rm -rf cleans it.
    local stub_bin="${TMPDIR_TEST}/bin/stubs"
    mkdir -p "$stub_bin"
    for _cmd in osascript notify-send; do
        printf '#!/bin/sh\nexit 0\n' > "$stub_bin/$_cmd"
        chmod +x "$stub_bin/$_cmd"
    done
    # Export PATH so the subshell spawned by tests (bash -c "HOME=... bash '${HOOK}'")
    # inherits the stub dir ahead of the real system binaries.
    export PATH="$stub_bin:$PATH"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

@test "benign invalid_request with unknown agent does not write event file" {
    run -0 bash -c "HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"session_id":"abc123","error":"invalid_request"}'
    [ "$status" -eq 0 ]
    count=$(ls "${BATS_EVENTS_DIR}/"*stop-failure*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 0 ]
}

@test "real failure with agent_type field writes event file" {
    run -0 bash -c "HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"agent_type":"code-writer","session_id":"abc123","error":"rate_limit_exceeded"}'
    [ "$status" -eq 0 ]
    count=$(ls "${BATS_EVENTS_DIR}/"*stop-failure*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ]
    content=$(cat "${BATS_EVENTS_DIR}/"*stop-failure*.json)
    echo "$content" | grep -q '"agent": "code-writer"'
}

@test "real failure with agent_name field writes event file" {
    run -0 bash -c "HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"agent_name":"debugger","session_id":"def456","error":"timeout"}'
    [ "$status" -eq 0 ]
    count=$(ls "${BATS_EVENTS_DIR}/"*stop-failure*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ]
}

@test "invalid_request with known agent_type still writes event file" {
    run -0 bash -c "HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"agent_type":"orchestrator","session_id":"ghi789","error":"invalid_request"}'
    [ "$status" -eq 0 ]
    count=$(ls "${BATS_EVENTS_DIR}/"*stop-failure*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ]
}

@test "writes to cast.db stop_failure_events table when db exists" {
    # Create a temporary cast.db
    TEST_DB="${BATS_FAKE_HOME}/.claude/cast.db"
    mkdir -p "${BATS_FAKE_HOME}/.claude"
    sqlite3 "$TEST_DB" "SELECT 1;" > /dev/null 2>&1

    run -0 bash -c "CAST_DB_PATH='${TEST_DB}' HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"agent_type":"test-agent","session_id":"xyz789","error":"test_failure"}'
    [ "$status" -eq 0 ]

    # Verify table was created
    table_exists=$(sqlite3 "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='stop_failure_events';" 2>/dev/null | tr -d ' ')
    [ "$table_exists" = "stop_failure_events" ]

    # Verify row was inserted
    row_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM stop_failure_events WHERE agent_name='test-agent';" 2>/dev/null | tr -d ' ')
    [ "$row_count" -eq 1 ]
}

@test "skips db write gracefully when cast.db is unavailable" {
    # Do not create a cast.db — should fail gracefully
    run -0 bash -c "CAST_DB_PATH='/nonexistent/cast.db' HOME='${BATS_FAKE_HOME}' bash '${HOOK}'" <<< '{"agent_type":"test-agent","session_id":"xyz789","error":"test_failure"}'
    [ "$status" -eq 0 ]
    # Should still write the event file
    count=$(ls "${BATS_EVENTS_DIR}/"*stop-failure*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 1 ]
}
