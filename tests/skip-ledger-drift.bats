#!/usr/bin/env bats
# tests/skip-ledger-drift.bats — Guard: docs/test-skip-ledger.md recorded total must
# match the actual skip-site count found by the canonical enumeration command.
#
# When a skip is added or removed the ledger MUST be updated; this test fails if they
# drift apart. Re-run the enumeration command (printed in the failure message) to get
# the current count, update the ledger, and this test will pass again.
#
# No temp-HOME isolation required: this test only reads source files, never touches
# ~/.claude or any live runtime state.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-check-skip-ledger.sh"

# This test exercises the real script (scripts/cast-check-skip-ledger.sh) rather
# than re-implementing the enumeration logic inline — that duplication is exactly
# what let the file-count half of this guard go unenforced for two drift cycles.
# Drift/error fixtures are written under $BATS_TEST_TMPDIR and passed via
# CAST_SKIP_LEDGER_PATH; the real tracked docs/test-skip-ledger.md is never mutated.

@test "skip-ledger: real ledger is in sync (call sites AND file count)" {
  run bash "$SCRIPT"
  assert_success
  assert_output --partial "OK: skip ledger in sync"
}

@test "skip-ledger: fails when call-site count drifts" {
  local fixture="$BATS_TEST_TMPDIR/ledger-sitedrift.md"
  sed -E 's/Total call sites: [0-9]+\*\*/Total call sites: 999**/' \
    "$REPO_DIR/docs/test-skip-ledger.md" > "$fixture"

  CAST_SKIP_LEDGER_PATH="$fixture" run bash "$SCRIPT"
  assert_failure
  assert_output --partial "DRIFT: call-site count"
}

@test "skip-ledger: fails when file count drifts" {
  local fixture="$BATS_TEST_TMPDIR/ledger-filedrift.md"
  sed -E 's/across [0-9]+ files/across 999 files/' \
    "$REPO_DIR/docs/test-skip-ledger.md" > "$fixture"

  CAST_SKIP_LEDGER_PATH="$fixture" run bash "$SCRIPT"
  assert_failure
  assert_output --partial "DRIFT: file count"
}

@test "skip-ledger: fails closed when ledger file is missing" {
  local missing="$BATS_TEST_TMPDIR/does-not-exist.md"

  CAST_SKIP_LEDGER_PATH="$missing" run bash "$SCRIPT"
  assert_failure
  assert_output --partial "ledger not found"
}

@test "skip-ledger: fails closed when ledger has no parseable anchor" {
  local fixture="$BATS_TEST_TMPDIR/ledger-no-anchor.md"
  echo "nothing useful here" > "$fixture"

  CAST_SKIP_LEDGER_PATH="$fixture" run bash "$SCRIPT"
  assert_failure
  assert_output --partial "no 'Total call sites"
}

@test "skip-ledger: fails closed when ledger anchor is ambiguous (matches twice)" {
  local fixture="$BATS_TEST_TMPDIR/ledger-double-anchor.md"
  printf '**Total call sites: 79** across 33 files\n**Total call sites: 79** across 33 files\n' > "$fixture"

  CAST_SKIP_LEDGER_PATH="$fixture" run bash "$SCRIPT"
  assert_failure
  assert_output --partial "expected exactly 1"
}

@test "skip-ledger: --help exits 0 without touching the ledger" {
  run bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "skip-ledger: rejects an unrecognised flag with exit 2, not silent success" {
  run bash "$SCRIPT" --bogus-flag
  assert_equal "$status" 2
  assert_output --partial "unrecognised argument"

  run bash "$SCRIPT" --check
  assert_equal "$status" 2
  assert_output --partial "unrecognised argument"
}
