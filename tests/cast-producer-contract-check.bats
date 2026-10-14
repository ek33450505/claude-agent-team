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

# --- line-content check: a numeric file:line must actually write the table ---

_plant_line_fixture() {
  # $1 = table name in contract, $2 = writer suffix (":N" or ":func (desc)")
  # Writers resolve under a fake root (absolute writer paths are refused by containment).
  export CAST_REPO_ROOT="$BATS_TEST_TMPDIR/fx-root"
  mkdir -p "$CAST_REPO_ROOT/scripts"
  FIXTURE="fixture-writer.sh"
  FIXTURE_PATH="$CAST_REPO_ROOT/scripts/$FIXTURE"
  cat > "$FIXTURE_PATH" <<'SH'
#!/usr/bin/env bash
# a comment line that says nothing useful
echo "INSERT INTO agent_runs_daily (day) VALUES ('x')"
echo "INSERT INTO agent_runs (agent) VALUES ('x')"
SH
  PLANTED="$BATS_TEST_TMPDIR/line-contract.json"
  cat > "$PLANTED" <<JSON
{"schema_version": "1.0", "tables": [
  {"table": "$1", "writers": ["$FIXTURE$2"], "cadence": "per_event", "status": "live"}
]}
JSON
}

@test "live writer: in-range line that does not write the table fails" {
  _plant_line_fixture agent_runs ":2"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 2 of"* ]]
  [[ "$output" == *"does not write agent_runs"* ]]
}

@test "live writer: line writing a different table (agent_runs_daily) does not satisfy agent_runs" {
  _plant_line_fixture agent_runs ":3"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not write agent_runs"* ]]
}

@test "live writer: line that really writes the table passes" {
  _plant_line_fixture agent_runs ":4"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 0 ]
}

@test "live writer: non-numeric file:func suffix still passes without a line check" {
  _plant_line_fixture agent_runs ":agent_runs_daily (indirect writer; identifier present in code)"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 0 ]
}

# --- identifier suffix + verb word-boundary checks ---

_plant_ident_fixture() {
  # $1 = writer suffix (e.g. ":some_fn")
  # Writers resolve under a fake root (absolute writer paths are refused by containment).
  export CAST_REPO_ROOT="$BATS_TEST_TMPDIR/fx-root"
  mkdir -p "$CAST_REPO_ROOT/scripts"
  FIXTURE="ident-writer.sh"
  FIXTURE_PATH="$CAST_REPO_ROOT/scripts/$FIXTURE"
  cat > "$FIXTURE_PATH" <<'SH'
#!/usr/bin/env bash
# only_in_comment is mentioned here but never used
real_fn() { echo hi; }
echo "row updated for agent_runs"
SH
  PLANTED="$BATS_TEST_TMPDIR/ident-contract.json"
  cat > "$PLANTED" <<JSON
{"schema_version": "1.0", "tables": [
  {"table": "agent_runs", "writers": ["$FIXTURE$1"], "cadence": "per_event", "status": "live"}
]}
JSON
}

@test "identifier suffix absent from the file fails" {
  _plant_ident_fixture ":no_such_fn"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"identifier no_such_fn not found"* ]]
}

@test "identifier suffix present only in a comment fails" {
  _plant_ident_fixture ":only_in_comment"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"identifier only_in_comment not found"* ]]
}

@test "identifier suffix present in code passes" {
  _plant_ident_fixture ":real_fn"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 0 ]
}

@test "line naming the table with only 'updated' is not a write" {
  _plant_ident_fixture ":4"
  run python3 "$CHECK_SCRIPT" --contract "$PLANTED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not write agent_runs"* ]]
}

# --- CAST_REPO_ROOT (installed-copy mode: the pre-commit hook passes the repo as data) ---

# Copy the checker OUTSIDE the repo, as the installed copy would be.
_outside_copy() {
  OUTSIDE_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/outside.XXXXXX")"
  cp "$CHECK_SCRIPT" "$OUTSIDE_DIR/cast-producer-contract-check.py"
  OUTSIDE_CHECK="$OUTSIDE_DIR/cast-producer-contract-check.py"
}

@test "CAST_REPO_ROOT: out-of-repo copy validates the repo named by the env var" {
  _outside_copy
  run env CAST_REPO_ROOT="$REPO_DIR" PYTHONDONTWRITEBYTECODE=1 python3 -I "$OUTSIDE_CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "CAST_REPO_ROOT control: the same out-of-repo copy WITHOUT the env var fails" {
  _outside_copy
  run env -u CAST_REPO_ROOT PYTHONDONTWRITEBYTECODE=1 python3 -I "$OUTSIDE_CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contract not found"* ]]
}

@test "CAST_REPO_ROOT: relative path is refused (fail closed)" {
  run env CAST_REPO_ROOT=relative/path PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CAST_REPO_ROOT must be an absolute path to an existing directory"* ]]
}

@test "CAST_REPO_ROOT: nonexistent absolute directory is refused" {
  run env CAST_REPO_ROOT="$BATS_TEST_TMPDIR/does-not-exist" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CAST_REPO_ROOT must be an absolute path"* ]]
}

_fake_root() {  # $1 = writer JSON literal; sets FAKE_ROOT
  FAKE_ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/fakeroot.XXXXXX")"
  mkdir -p "$FAKE_ROOT/config" "$FAKE_ROOT/scripts"
  printf '{"tables":[{"table":"t1","status":"live","writers":[%s]}]}\n' "$1" > "$FAKE_ROOT/config/producer-contract.json"
}

@test "CAST_REPO_ROOT: bare writer is NOT found at the root, only under scripts/" {
  _fake_root '"tool.sh"'
  echo "x" > "$FAKE_ROOT/tool.sh"
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"file not found"* ]]
}

@test "CAST_REPO_ROOT: bare writer present under the env root's scripts/ passes" {
  _fake_root '"ok.sh"'
  echo "x" > "$FAKE_ROOT/scripts/ok.sh"
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "containment: absolute writer path is refused and not read" {
  _fake_root '"/etc/hosts:1"'
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writer path escapes the repo root"* ]]
  [[ "$output" != *"localhost"* ]]
}

@test "containment: ../ escape is refused" {
  _fake_root '"../outside.sh"'
  echo "x" > "$BATS_TEST_TMPDIR/outside.sh"
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writer path escapes the repo root"* ]]
}

@test "containment: symlink under scripts/ pointing outside the root is refused" {
  _fake_root '"link.sh"'
  echo "x" > "$BATS_TEST_TMPDIR/target.sh"
  ln -s "$BATS_TEST_TMPDIR/target.sh" "$FAKE_ROOT/scripts/link.sh"
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writer path escapes the repo root"* ]]
}

@test "non-string writer entry is reported as an error, no traceback" {
  _fake_root '5'
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writer is not a string"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "containment: writer with an embedded NUL byte is an error entry, not a crash" {
  _fake_root '"a\u0000b.py:1"'
  run env CAST_REPO_ROOT="$FAKE_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not resolvable"* ]]
  [[ "$output" != *"Traceback"* ]]
}
