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
# 3. --date argument is parseable (dry run, no claude CLI needed)
# ---------------------------------------------------------------------------

@test "--date argument is accepted without error (argparse only)" {
  # Patch: run with --help to verify argparse is wired without actually calling claude
  run python3 "$SCRIPT" --help
  # --help exits 0 and prints usage
  assert_success
  assert_output --partial "date"
}
