#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-morning-briefing-sdk.py"

# ---------------------------------------------------------------------------
# 1. Script exists
# ---------------------------------------------------------------------------

@test "cast-morning-briefing-sdk.py exists in scripts/" {
  [ -f "$SCRIPT" ]
}

# ---------------------------------------------------------------------------
# 2. Valid Python syntax
# ---------------------------------------------------------------------------

@test "script passes python3 syntax check (py_compile)" {
  run python3 -m py_compile "$SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 3. Contains import statement
# ---------------------------------------------------------------------------

@test "script contains import statements" {
  run grep -q "^import\|^from " "$SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 4. Contains argparse / --date argument handling
# ---------------------------------------------------------------------------

@test "script contains argparse for --date argument" {
  run grep -q "argparse\|--date" "$SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 5. Non-trivial size (more than 10 lines)
# ---------------------------------------------------------------------------

@test "script has more than 10 lines" {
  local lines
  lines=$(wc -l < "$SCRIPT")
  [ "$lines" -gt 10 ]
}

# ---------------------------------------------------------------------------
# 6. Contains if __name__ == '__main__' guard
# ---------------------------------------------------------------------------

@test "script has __main__ guard" {
  run grep -q "__name__" "$SCRIPT"
  assert_success
}

# ---------------------------------------------------------------------------
# 7. --date argument is parseable (dry run, no claude CLI needed)
# ---------------------------------------------------------------------------

@test "--date argument is accepted without error (argparse only)" {
  # Patch: run with --help to verify argparse is wired without actually calling claude
  run python3 "$SCRIPT" --help
  # --help exits 0 and prints usage
  assert_success
  assert_output --partial "date"
}
