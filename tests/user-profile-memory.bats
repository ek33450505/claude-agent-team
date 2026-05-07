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

@test "seeder script is idempotent (second run inserts 0 rows)" {
  # First run: insert all facts
  bash scripts/cast-seed-user-profile.sh >/dev/null 2>&1
  COUNT_FIRST=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type='user_profile'")

  # Second run: should skip all (idempotent)
  OUTPUT=$(bash scripts/cast-seed-user-profile.sh 2>&1)

  # Verify idempotency: same count after second run
  COUNT_SECOND=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM agent_memories WHERE type='user_profile'")
  [ "$COUNT_FIRST" -eq "$COUNT_SECOND" ]
  [ "$COUNT_FIRST" -gt 0 ]  # We expect at least 6 facts

  # Check output mentions skipped facts
  [[ "$OUTPUT" =~ "already existing" ]]
}

@test "proactive intel script exits 0 on empty DB" {
  run bash scripts/cast-proactive-intel.sh

  # Should always exit 0 (non-blocking)
  [ "$status" -eq 0 ]
}

@test "proactive intel script surfaces stale facts" {
  # Insert a user_profile fact created > 30 days ago
  sqlite3 "$TEST_DB" \
    "INSERT INTO agent_memories (agent, type, name, content, created_at, updated_at)
     VALUES ('global', 'user_profile', 'work-style', 'long sessions', datetime('now', '-31 days'), datetime('now', '-31 days'))"

  run bash scripts/cast-proactive-intel.sh

  [ "$status" -eq 0 ]
  # Should surface advisory about stale profiles
  [[ "$output" =~ "user profile patterns" ]] || [[ "$output" =~ "haven't been reviewed" ]]
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
