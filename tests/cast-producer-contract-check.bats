#!/usr/bin/env bats
# tests/cast-producer-contract-check.bats — tests for scripts/cast-producer-contract-check.py
#
# Coverage:
#   - passing case: the real (fully repoint-fixed) config/producer-contract.json
#     validates clean end-to-end
#   - failing case: a planted "live" writer pointing at a nonexistent script is
#     caught (exit 1 + the dangling entry named in the message) — probes the
#     checker on its REAL default resolution path (bare filename -> scripts/),
#     not a synthetic in-process call
#   - non-"live" statuses are intentionally skipped (dormant table with a fake
#     writer must not fail the check)
#   - a missing contract file exits 1 with a clear message, not a traceback
#
# Isolated temp HOME: the checker itself never touches $HOME or cast.db (it
# only reads a JSON config + stats files under the repo tree), but the suite
# still isolates per the blanket HARD RULE (any test may run alongside others
# that do touch $HOME).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK_SCRIPT="$REPO_DIR/scripts/cast-producer-contract-check.py"
REAL_CONTRACT="$REPO_DIR/config/producer-contract.json"

setup() {
  load 'helpers/setup'
  setup_temp_home
}

teardown() {
  teardown_temp_home
}

@test "checker script exists and is executable" {
  [ -x "$CHECK_SCRIPT" ]
}

@test "passing case: the real producer-contract.json validates clean" {
  # All 7 dangling live-table writers surfaced during this fix (the original 3
  # + 4 more the validator found once it existed) are now repointed, so the
  # full real contract is asserted clean directly — no slicing needed.
  run python3 "$CHECK_SCRIPT" --contract "$REAL_CONTRACT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "failing case: a live writer pointing at a nonexistent script is caught" {
  # Plant a corrupted contract: a "live" table's writer points at a script that
  # does not exist anywhere in scripts/. No env overrides — --contract is a
  # normal CLI parameter (mirrors cast-db-contract.py's --baseline), not a
  # bypass; this exercises the checker's real default bare-filename ->
  # scripts/ resolution path.
  local PLANTED="$BATS_TEST_TMPDIR/planted-contract.json"
  cat > "$PLANTED" <<'JSON'
{
  "schema_version": "1.0",
  "tables": [
    {
      "table": "fake_table",
      "writers": ["cast-totally-fake-script-does-not-exist.sh:99"],
      "cadence": "per_event",
      "status": "live"
    }
  ]
}
JSON

  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cast-totally-fake-script-does-not-exist.sh"* ]]
  [[ "$output" == *"fake_table"* ]]
}

@test "non-live statuses are not checked (dormant table with a fake writer passes)" {
  local PLANTED="$BATS_TEST_TMPDIR/dormant-contract.json"
  cat > "$PLANTED" <<'JSON'
{
  "schema_version": "1.0",
  "tables": [
    {
      "table": "some_dormant_table",
      "writers": ["also-fake-but-not-live.py:1"],
      "cadence": "on_demand",
      "status": "dormant"
    }
  ]
}
JSON

  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 0 ]
}

@test "missing contract file exits 1 with a clear message" {
  run python3 "$CHECK_SCRIPT" --contract "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}
