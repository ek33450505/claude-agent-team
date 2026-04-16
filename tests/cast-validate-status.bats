#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_DIR/scripts/cast-validate-status.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_validator() {
  run python3 "$VALIDATOR" "$@"
}

# ---------------------------------------------------------------------------
# 1. Valid DONE (minimal)
# ---------------------------------------------------------------------------

@test "valid: DONE status with required fields only exits 0 and prints VALID" {
  run_validator <<< '{"status":"DONE","summary":"Committed three files","agent":"commit"}'
  assert_success
  assert_output "VALID"
}

# ---------------------------------------------------------------------------
# 2. Valid DONE_WITH_CONCERNS with concerns array
# ---------------------------------------------------------------------------

@test "valid: DONE_WITH_CONCERNS with concerns array exits 0" {
  run_validator <<< '{
    "status": "DONE_WITH_CONCERNS",
    "summary": "Tests written but coverage is low at 42%",
    "agent": "test-writer",
    "concerns": ["Coverage below 60% threshold", "Edge case for empty input not covered"]
  }'
  assert_success
  assert_output "VALID"
}

# ---------------------------------------------------------------------------
# 3. Valid BLOCKED with blockers
# ---------------------------------------------------------------------------

@test "valid: BLOCKED with blockers array exits 0" {
  run_validator <<< '{
    "status": "BLOCKED",
    "summary": "Cannot proceed — npm install failed with exit 1",
    "agent": "debugger",
    "blockers": ["npm install failed: ENOENT package-lock.json"]
  }'
  assert_success
  assert_output "VALID"
}

# ---------------------------------------------------------------------------
# 4. Valid NEEDS_CONTEXT with context_needed
# ---------------------------------------------------------------------------

@test "valid: NEEDS_CONTEXT with context_needed exits 0" {
  run_validator <<< '{
    "status": "NEEDS_CONTEXT",
    "summary": "Need clarification on scope before proceeding",
    "agent": "planner",
    "context_needed": ["Which database should the migration target?", "What is the deadline for Wave 3?"]
  }'
  assert_success
  assert_output "VALID"
}

# ---------------------------------------------------------------------------
# 5. Valid with all optional fields
# ---------------------------------------------------------------------------

@test "valid: all optional fields accepted" {
  run_validator <<< '{
    "status": "DONE",
    "summary": "Refactored auth module",
    "agent": "code-writer",
    "files_changed": ["/home/user/project/src/auth.ts", "/home/user/project/src/auth.test.ts"],
    "next_actions": ["Run integration tests", "Update API docs"],
    "schema_version": "1.0"
  }'
  assert_success
  assert_output "VALID"
}

# ---------------------------------------------------------------------------
# 6. Invalid: missing status field
# ---------------------------------------------------------------------------

@test "invalid: missing status field exits 1 with clear error" {
  run_validator <<< '{"summary":"Did something","agent":"commit"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "status"
}

# ---------------------------------------------------------------------------
# 7. Invalid: unknown status enum value
# ---------------------------------------------------------------------------

@test "invalid: unknown status value exits 1" {
  run_validator <<< '{"status":"PENDING","summary":"Did something","agent":"commit"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "PENDING"
}

# ---------------------------------------------------------------------------
# 8. Invalid: BLOCKED without blockers
# ---------------------------------------------------------------------------

@test "invalid: BLOCKED without blockers exits 1 with clear error" {
  run_validator <<< '{"status":"BLOCKED","summary":"Stuck on something","agent":"debugger"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "blockers"
  assert_output --partial "BLOCKED"
}

# ---------------------------------------------------------------------------
# 9. Invalid: non-JSON input
# ---------------------------------------------------------------------------

@test "invalid: non-JSON input exits 1" {
  run_validator <<< 'Status: DONE'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "JSON"
}

# ---------------------------------------------------------------------------
# 10. Malformed files_changed (not array)
# ---------------------------------------------------------------------------

@test "invalid: files_changed is not an array exits 1" {
  run_validator <<< '{
    "status": "DONE",
    "summary": "Did work",
    "agent": "code-writer",
    "files_changed": "/path/to/file.ts"
  }'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "files_changed"
}

# ---------------------------------------------------------------------------
# 11. Invalid: missing summary
# ---------------------------------------------------------------------------

@test "invalid: missing summary field exits 1" {
  run_validator <<< '{"status":"DONE","agent":"commit"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "summary"
}

# ---------------------------------------------------------------------------
# 12. Invalid: missing agent
# ---------------------------------------------------------------------------

@test "invalid: missing agent field exits 1" {
  run_validator <<< '{"status":"DONE","summary":"All done"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "agent"
}

# ---------------------------------------------------------------------------
# 13. Invalid: DONE_WITH_CONCERNS without concerns
# ---------------------------------------------------------------------------

@test "invalid: DONE_WITH_CONCERNS without concerns exits 1" {
  run_validator <<< '{"status":"DONE_WITH_CONCERNS","summary":"Done but worried","agent":"code-writer"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "concerns"
  assert_output --partial "DONE_WITH_CONCERNS"
}

# ---------------------------------------------------------------------------
# 14. Invalid: NEEDS_CONTEXT without context_needed
# ---------------------------------------------------------------------------

@test "invalid: NEEDS_CONTEXT without context_needed exits 1" {
  run_validator <<< '{"status":"NEEDS_CONTEXT","summary":"Need more info","agent":"planner"}'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "context_needed"
  assert_output --partial "NEEDS_CONTEXT"
}

# ---------------------------------------------------------------------------
# 15. Invalid: summary too long
# ---------------------------------------------------------------------------

@test "invalid: summary exceeding 300 chars exits 1" {
  long_summary="$(python3 -c "print('x' * 301)")"
  run_validator <<< "{\"status\":\"DONE\",\"summary\":\"$long_summary\",\"agent\":\"commit\"}"
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "summary"
}

# ---------------------------------------------------------------------------
# 16. Invalid: unexpected additional field
# ---------------------------------------------------------------------------

@test "invalid: unexpected field exits 1" {
  run_validator <<< '{
    "status": "DONE",
    "summary": "Done",
    "agent": "commit",
    "foo_bar_baz": "extra"
  }'
  assert_failure
  assert_output --partial "INVALID:"
  assert_output --partial "foo_bar_baz"
}

# ---------------------------------------------------------------------------
# 17. File argument input mode
# ---------------------------------------------------------------------------

@test "valid: accepts file path as argument" {
  local tmpfile
  tmpfile="$(mktemp /tmp/cast-status-test-XXXXXX.json)"
  printf '{"status":"DONE","summary":"Test via file","agent":"test-writer"}' > "$tmpfile"
  run_validator "$tmpfile"
  assert_success
  assert_output "VALID"
  rm -f "$tmpfile"
}
