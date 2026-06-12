#!/usr/bin/env bats
# tests/cast-blast-radius-guard.bats — Prove-refusal tests for scripts/cast-guard-lib.sh
#
# Tests the 5 required refusal cases from the blast-radius design doc Q4, plus
# the fail-closed case (no declaration made).
#
# Isolation: tests that need HOME manipulation use setup_temp_home/teardown_temp_home.
# All other tests operate purely on mktemp fixtures so HOME is never the operand.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Each @test runs in its own subshell; source the lib fresh.
  source "$REPO_DIR/scripts/cast-guard-lib.sh"
}

# ---------------------------------------------------------------------------
# 1. Refuse out-of-radius — target outside the declared prefix → FATAL + canary survives
# ---------------------------------------------------------------------------
@test "cast_safe_rm refuses path outside blast radius (canary survives)" {
  local outside
  outside="$(mktemp -d)"
  touch "$outside/canary"

  cast_declare_blast_radius "/tmp/cast-allowed-root-${BATS_TEST_NUMBER}-$$"

  run cast_safe_rm "$outside"
  assert_failure
  assert_output --partial "FATAL"

  # Canary must survive the refused delete
  [ -f "$outside/canary" ]

  rm -rf "$outside"
}

# ---------------------------------------------------------------------------
# 2. Allow in-radius — target inside declared root → succeeds + target removed
# ---------------------------------------------------------------------------
@test "cast_safe_rm allows path strictly inside blast radius (target removed)" {
  local radius target
  radius="$(mktemp -d)"
  # Build a sub-directory that starts with the radius path
  target="${radius}/sub-${BATS_TEST_NUMBER}-$$"
  mkdir "$target"
  touch "$target/file"

  # Declare with trailing slash so the radius directory itself is excluded
  cast_declare_blast_radius "${radius}/"

  run cast_safe_rm "$target"
  assert_success

  [ ! -d "$target" ]

  rm -rf "$radius"
}

# ---------------------------------------------------------------------------
# 3. Refuse home — blast radius declared elsewhere, target is $HOME → FATAL
#    Uses a synthetic HOME via setup_temp_home so real home is never the operand.
# ---------------------------------------------------------------------------
@test "cast_safe_rm refuses user home directory (FATAL)" {
  setup_temp_home

  cast_declare_blast_radius "/tmp/not-home-${BATS_TEST_NUMBER}-$$"

  run cast_safe_rm "$HOME"
  assert_failure
  assert_output --partial "FATAL"

  teardown_temp_home
}

# ---------------------------------------------------------------------------
# 4. Refuse symlink escape — symlink inside radius resolving outside → FATAL
#    Link target (the directory the symlink points to) must survive.
# ---------------------------------------------------------------------------
@test "cast_safe_rm refuses symlink that escapes blast radius (link target survives)" {
  local radius outside link_target link_path
  radius="$(mktemp -d)"
  outside="$(mktemp -d)"
  link_target="${outside}/escape-target"
  mkdir "$link_target"
  touch "$link_target/canary"

  # Place a symlink inside the radius that resolves to the outside directory
  link_path="${radius}/escape-link"
  ln -s "$link_target" "$link_path"

  # Declare the radius (trailing slash → link_path is inside, but resolves outside)
  cast_declare_blast_radius "${radius}/"

  run cast_safe_rm "$link_path"
  assert_failure
  assert_output --partial "FATAL"

  # Link target (and its canary) must survive
  [ -f "$link_target/canary" ]

  rm -rf "$radius" "$outside"
}

# ---------------------------------------------------------------------------
# 5. Refuse root equality — path == declared radius prefix root → FATAL
#    The path must be STRICTLY INSIDE the prefix, not equal to it.
# ---------------------------------------------------------------------------
@test "cast_safe_rm refuses path equal to declared blast radius prefix root (FATAL)" {
  # Use a prefix with no trailing slash so equality test is clear
  local prefix
  prefix="/tmp/cast-guard-root-${BATS_TEST_NUMBER}-$$"
  mkdir -p "$prefix"

  cast_declare_blast_radius "$prefix"

  run cast_safe_rm "$prefix"
  assert_failure
  assert_output --partial "FATAL"

  # The directory itself must survive
  [ -d "$prefix" ]

  rm -rf "$prefix"
}

# ---------------------------------------------------------------------------
# 6. No declaration → FATAL (fail-closed default)
# ---------------------------------------------------------------------------
@test "cast_safe_rm with no blast radius declared fails closed (FATAL)" {
  local target
  target="$(mktemp -d)"

  # Deliberately do NOT call cast_declare_blast_radius
  run cast_safe_rm "$target"
  assert_failure
  assert_output --partial "FATAL"

  # Directory must survive
  [ -d "$target" ]

  rm -rf "$target"
}
