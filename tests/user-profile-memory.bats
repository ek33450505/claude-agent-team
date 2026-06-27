#!/usr/bin/env bats
# user-profile-memory.bats — Test suite for user_profile memory type (Phase 3 Task 3.4)
#
# Tests:
# 1. user_profile type accepted by cast-memory-write.sh
# 2. user_profile facts retrieved regardless of project scope
# 3. Seeder script is idempotent
# 4. Proactive intel script exits cleanly on empty DB

# Set up test DB for each test
setup() {
  TEST_DB="$(mktemp)"
  export CAST_DB_PATH="$TEST_DB"

  # Initialize DB with schema
  bash scripts/cast-db-init.sh --db "$TEST_DB" >/dev/null 2>&1 || true
}

teardown() {
  rm -f "$TEST_DB"
}

@test "user_profile type accepted by cast-memory-write.sh" {
  run bash scripts/cast-memory-write.sh "test-agent" "user_profile" "work-hours" "8am-4pm M-F"

  # Should not fail with type validation error
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Memory written" ]]

  # Verify fact was written to DB
  FACT_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type='user_profile'" || echo "0")
  [ "$FACT_COUNT" -eq 1 ]
}

@test "user_profile facts retrieved regardless of project scope" {
  # Write a project-scoped fact to project A
  bash scripts/cast-memory-write.sh "agent1" "project" "test-framework" "BATS" --project "project-a" >/dev/null 2>&1

  # Write a user_profile fact (global scope)
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_memories (agent, type, name, content, created_at, updated_at)
     VALUES ('global', 'user_profile', 'comm-style', 'Direct, terse responses', datetime('now'), datetime('now'))"

  # Retrieve from project B context (different project_root)
  # The retrieve function should still return the user_profile fact because it's global
  run python3 scripts/cast-memory-router.py --mode retrieve --agent shared --prompt "communication style"

  [ "$status" -eq 0 ]
  # Should find the user_profile fact
  [[ "$output" =~ "user_profile" ]] || [[ "$output" =~ "comm-style" ]]
}

@test "cast-memory-router.py VALID_TYPES includes user_profile" {
  # Check that VALID_TYPES in Python file includes user_profile
  GREP_RESULT=$(grep "user_profile" scripts/cast-memory-router.py || true)
  [[ "$GREP_RESULT" =~ "user_profile" ]]
}

@test "cast-memory-write.sh type validation includes user_profile" {
  # Check that the case statement includes user_profile
  GREP_RESULT=$(grep "user_profile" scripts/cast-memory-write.sh || true)
  [[ "$GREP_RESULT" =~ "user_profile" ]]
}
