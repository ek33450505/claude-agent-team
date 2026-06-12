#!/usr/bin/env bats
# Tests for cast-contract-runner.sh and cast_contract_runner.py
# Fixture-based contract testing — no live API calls

setup() {
  load 'helpers/setup'
  setup_temp_home
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export CAST_DB_PATH="${BATS_TMPDIR}/test-cast.db"
  mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/logs"
}

teardown() {
  teardown_temp_home
  rm -f "$CAST_DB_PATH"
}

# Test 1: Runner with passing fixture exits 0
@test "runner with passing fixture exits 0" {
  local fixture_dir="${REPO_ROOT}/agent-contracts/fixtures"
  mkdir -p "$fixture_dir"

  cat > "$fixture_dir/test-pass-basic.txt" <<'FIXTURE'
Status: DONE
Summary: Created a commit

## Work Log
- Commit created successfully
FIXTURE

  # Create minimal contract file
  cat > "${REPO_ROOT}/agent-contracts/test-pass.contract.yaml" <<'CONTRACT'
agent: test-pass
version: "1.0"
assertions:
  - type: output_contains
    pattern: "Status: DONE"
fixtures:
  - name: "basic"
CONTRACT

  run bash "${REPO_ROOT}/scripts/cast-contract-runner.sh" test-pass
  [ "$status" -eq 0 ]
}

# Regression guard: contract_test_runs was dropped in Wave-3 Inc 2; runner must not re-accrete it.
@test "runner does not create contract_test_runs table in cast.db" {
  local fixture_dir="${REPO_ROOT}/agent-contracts/fixtures"
  mkdir -p "$fixture_dir"

  cat > "$fixture_dir/test-pass-basic.txt" <<'FIXTURE'
Status: DONE
Summary: Created a commit

## Work Log
- Commit created successfully
FIXTURE

  cat > "${REPO_ROOT}/agent-contracts/test-pass.contract.yaml" <<'CONTRACT'
agent: test-pass
version: "1.0"
assertions:
  - type: output_contains
    pattern: "Status: DONE"
fixtures:
  - name: "basic"
CONTRACT

  run bash "${REPO_ROOT}/scripts/cast-contract-runner.sh" test-pass

  # DB must not exist at all, or if it does (other writes), must lack the table
  if [ -f "$CAST_DB_PATH" ]; then
    result="$(sqlite3 "$CAST_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='contract_test_runs';")"
    [ -z "$result" ]
  fi
}

# Test 2: Runner with failing assertion exits 1
@test "runner with failing assertion exits 1" {
  local fixture_dir="${REPO_ROOT}/agent-contracts/fixtures"
  mkdir -p "$fixture_dir"

  # Create fixture with missing content
  cat > "$fixture_dir/test-fail-basic.txt" <<'FIXTURE'
Status: INCOMPLETE
Summary: Something went wrong
FIXTURE

  # Create contract that expects content not in fixture
  cat > "${REPO_ROOT}/agent-contracts/test-fail.contract.yaml" <<'CONTRACT'
agent: test-fail
version: "1.0"
assertions:
  - type: output_contains
    pattern: "Status: DONE"
fixtures:
  - name: "basic"
CONTRACT

  run bash "${REPO_ROOT}/scripts/cast-contract-runner.sh" test-fail
  [ "$status" -eq 1 ]
}

# Test 3: output_contains passes with matching regex
@test "output_contains assertion passes with matching regex" {
  local assertions_json='[{"type":"output_contains","pattern":"Status: (DONE|BLOCKED)"}]'
  local fixture_content="Status: DONE
Test complete"

  run env CAST_FIXTURE_CONTENT="$fixture_content" CAST_ASSERTIONS_JSON="$assertions_json" \
    python3 "${REPO_ROOT}/scripts/cast_contract_runner.py"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"passed": true'
}

# Test 4: output_contains fails with non-matching regex
@test "output_contains assertion fails with non-matching regex" {
  local assertions_json='[{"type":"output_contains","pattern":"Status: DONE"}]'
  local fixture_content="Status: INCOMPLETE
Work in progress"

  run env CAST_FIXTURE_CONTENT="$fixture_content" CAST_ASSERTIONS_JSON="$assertions_json" \
    python3 "${REPO_ROOT}/scripts/cast_contract_runner.py"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q '"passed": false'
}

# Test 5: cast_db_write assertion checks DB row (mocked)
@test "cast_db_write assertion checks DB row exists" {
  # Pre-populate test table
  sqlite3 "$CAST_DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS agent_runs (
    id INTEGER PRIMARY KEY,
    agent_name TEXT,
    status TEXT
);
INSERT INTO agent_runs (agent_name, status) VALUES ('commit', 'DONE');
SQL

  local assertions_json='[{"type":"cast_db_write","table":"agent_runs","field":"agent_name","expected":"commit"}]'
  local fixture_content="Test output"

  run env CAST_FIXTURE_CONTENT="$fixture_content" CAST_ASSERTIONS_JSON="$assertions_json" \
    python3 "${REPO_ROOT}/scripts/cast_contract_runner.py"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"passed": true'
}

# Test 6: cast test --help exits 0
@test "cast test --help exits 0" {
  run bash "${REPO_ROOT}/bin/cast" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "test"
}
