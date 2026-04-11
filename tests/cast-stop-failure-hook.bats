#!/usr/bin/env bats
# cast-stop-failure-hook.bats
# Regression tests for cast-stop-failure-hook.sh
#
# Covers:
#   (1) Benign invalid_request with unknown agent must NOT write an event file
#   (2) Real failure with identifiable agent MUST write an event file
#   (3) agent_type field is correctly used to identify the agent

bats_require_minimum_version 1.5.0

HOOK="${HOME}/.claude/scripts/cast-stop-failure-hook.sh"

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    FAKE_HOME="${TMPDIR_TEST}/home"
    mkdir -p "${FAKE_HOME}/.claude/cast/events"
    mkdir -p "${FAKE_HOME}/.claude/logs"
    export BATS_FAKE_HOME="$FAKE_HOME"
    export BATS_EVENTS_DIR="${FAKE_HOME}/.claude/cast/events"
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
