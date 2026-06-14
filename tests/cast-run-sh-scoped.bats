#!/usr/bin/env bats
# Tests for tests/run.sh --files SCOPED mode (CAST v8 A5).
#
# HARD RULE: never run the real suite against the real tests/ directory or real $HOME.
# Every test here drives a COPY of run.sh inside a throwaway "fake repo" whose tests/
# contains only tiny printf-built fixtures, and uses setup_temp_home for the BATS
# process itself. The copied run.sh also creates its own internal temp HOME, so the
# real ~/.claude is never touched on any path.
#
# NOTE: fixtures are written with printf, NOT shell heredocs — BATS preprocesses its
# own source and rewrites any "@test" lines it finds (including inside heredocs).
# printf arguments are plain strings and bypass that transformation.
#
# No GUI shim needed: fixtures are `true`-only @tests and the only seeded script is
# cast-count-planned-tests.sh — nothing here calls osascript/open/notify-send.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load 'helpers/setup'
  setup_temp_home
  FAKES=()
}

teardown() {
  for _d in "${FAKES[@]+"${FAKES[@]}"}"; do
    rm -rf "$_d"
  done
  teardown_temp_home
}

# Build a throwaway fake repo: a copy of run.sh + the planned-count helper, with an
# empty tests/ dir for the caller to populate with fixtures. Echoes the repo path.
_new_fake() {
  local f
  f="$(mktemp -d)"
  FAKES+=("$f")
  mkdir -p "$f/tests" "$f/scripts"
  cp "$REPO_DIR/tests/run.sh" "$f/tests/run.sh"
  cp "$REPO_DIR/scripts/cast-count-planned-tests.sh" "$f/scripts/cast-count-planned-tests.sh"
  chmod +x "$f/tests/run.sh" "$f/scripts/cast-count-planned-tests.sh"
  printf '%s' "$f"
}

# ---------------------------------------------------------------------------
# (1) --files runs ONLY the listed file — TAP plan == that file's @test count
# ---------------------------------------------------------------------------

@test "scoped: --files runs ONLY the named file, not the full suite" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n@test "a2" { true; }\n' > "$fake/tests/alpha.bats"
  printf '@test "b1" { true; }\n@test "b2" { true; }\n@test "b3" { true; }\n' > "$fake/tests/beta.bats"
  printf '@test "g1" { true; }\n' > "$fake/tests/gamma.bats"
  # Full suite would be 6 tests; scoping to alpha must yield exactly 2.

  run bash "$fake/tests/run.sh" --files tests/alpha.bats --tap
  assert_success
  assert_output --partial "1..2"
  refute_output --partial "1..6"
  assert_output --partial "SCOPED run (1 file(s))"
}

# ---------------------------------------------------------------------------
# (2) PLANNED scopes to the subset (multi-file subset, not the whole repo)
# ---------------------------------------------------------------------------

@test "scoped: PLANNED scopes to the requested subset" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n@test "a2" { true; }\n' > "$fake/tests/alpha.bats"
  printf '@test "b1" { true; }\n@test "b2" { true; }\n@test "b3" { true; }\n' > "$fake/tests/beta.bats"
  printf '@test "g1" { true; }\n' > "$fake/tests/gamma.bats"
  # alpha (2) + beta (3) = 5, deliberately excluding gamma. Full would be 6.

  run bash "$fake/tests/run.sh" --files tests/alpha.bats tests/beta.bats --tap
  assert_success
  assert_output --partial "1..5"
  refute_output --partial "1..6"
  assert_output --partial "SCOPED run (2 file(s))"
}

# ---------------------------------------------------------------------------
# (3) count-gate still fires in scoped mode when a requested file's tests are
#     dropped at run time (counted as planned, but bats does not execute them)
# ---------------------------------------------------------------------------

@test "scoped: count-gate FAILS when a requested file is silently dropped" {
  local fake; fake="$(_new_fake)"
  printf '@test "ok1" { true; }\n' > "$fake/tests/good.bats"
  # broken.bats has 2 @test lines (counted as planned=2 here) but a load error
  # makes bats drop them at run time -> executed != planned -> gate must fire.
  printf 'load "this_helper_does_not_exist"\n@test "drop1" { true; }\n@test "drop2" { true; }\n' > "$fake/tests/broken.bats"

  run bash "$fake/tests/run.sh" --files tests/good.bats tests/broken.bats --tap
  assert_failure
  assert_output --partial "[cast-count-gate] FAIL"
}

# ---------------------------------------------------------------------------
# (3b) a requested file that does not exist is rejected up front
# ---------------------------------------------------------------------------

@test "scoped: a missing requested file is rejected (no silent full-suite fallback)" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n' > "$fake/tests/alpha.bats"

  run bash "$fake/tests/run.sh" --files tests/does-not-exist.bats --tap
  assert_failure
  assert_output --partial "is not an existing file"
  # It must NOT have silently run the (existing) full suite instead.
  refute_output --partial "1..1"
}

# ---------------------------------------------------------------------------
# (4) non-existent path shapes are rejected (exit 1): absolute, non-.bats, ..
# ---------------------------------------------------------------------------

@test "scoped: an absolute path is rejected" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n' > "$fake/tests/alpha.bats"

  run bash "$fake/tests/run.sh" --files /etc/hosts --tap
  assert_failure
  assert_output --partial "must be a tests/*.bats path"
}

@test "scoped: a non-.bats path is rejected" {
  local fake; fake="$(_new_fake)"
  printf 'not a test\n' > "$fake/tests/alpha.txt"

  run bash "$fake/tests/run.sh" --files tests/alpha.txt --tap
  assert_failure
  assert_output --partial "must be a tests/*.bats path"
}

@test "scoped: a '..' traversal path is rejected" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n' > "$fake/tests/alpha.bats"

  run bash "$fake/tests/run.sh" --files tests/../tests/alpha.bats --tap
  assert_failure
  assert_output --partial "must not contain '..'"
}

@test "scoped: --files with no file argument is rejected" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n' > "$fake/tests/alpha.bats"

  run bash "$fake/tests/run.sh" --files --tap
  assert_failure
  assert_output --partial "requires at least one"
}

# ---------------------------------------------------------------------------
# (5) full-suite path (no --files) still works
# ---------------------------------------------------------------------------

@test "full: no --files runs the whole (glob) suite" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n@test "a2" { true; }\n' > "$fake/tests/alpha.bats"
  printf '@test "b1" { true; }\n@test "b2" { true; }\n@test "b3" { true; }\n' > "$fake/tests/beta.bats"
  printf '@test "g1" { true; }\n' > "$fake/tests/gamma.bats"
  # No --files -> glob picks all three -> 6 tests.

  run bash "$fake/tests/run.sh" --tap
  assert_success
  assert_output --partial "1..6"
  refute_output --partial "SCOPED run"
}

@test "full: passthrough flag still flows to bats without --files" {
  local fake; fake="$(_new_fake)"
  printf '@test "a1" { true; }\n' > "$fake/tests/alpha.bats"

  run bash "$fake/tests/run.sh" --tap
  assert_success
  assert_output --partial "1..1"
  assert_output --partial "ok 1"
}
