#!/usr/bin/env bats
# Regression coverage for scripts/cast-overlay-sync.sh
#
# Focus: the durable git-identity fix (2026-07-09). The daily overlay push to
# the private repo failed with GH007 (private-email push-protection) because
# the overlay clone's local git config carried a real email address. A
# one-time manual `git config` fix on the existing clone was NOT durable — a
# fresh clone would reintroduce the bug. This test asserts the script sets
# the correct noreply identity, in the overlay dir's LOCAL config, on every
# run — using a fake local bare repo as "origin", never the real overlay dir
# or real GitHub.

load helpers/setup

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cast-overlay-sync.sh"

EXPECTED_EMAIL="97137083+ek33450505@users.noreply.github.com"
EXPECTED_NAME="Edward Kubiak"

setup() {
  setup_temp_home

  # Isolated fake "origin": a local bare repo, never the real overlay repo.
  FAKE_REMOTE="$BATS_TEST_TMPDIR/fake-origin.git"
  git init --bare -q "$FAKE_REMOTE"

  # Pre-seed the overlay dir as an existing clone of the fake remote, so the
  # script's "clone if missing" branch (which calls `gh repo create`) is
  # skipped entirely — no real GitHub interaction.
  OVERLAY_DIR="$BATS_TEST_TMPDIR/overlay"
  git clone -q "$FAKE_REMOTE" "$OVERLAY_DIR"

  # Seed a real (non-noreply) identity + an initial commit, mirroring the
  # confirmed-buggy pre-fix state, so we can prove the script corrects it.
  git -C "$OVERLAY_DIR" config user.email "test-real-address@example.com"
  git -C "$OVERLAY_DIR" config user.name "Edward Kubiak (real)"
  git -C "$OVERLAY_DIR" checkout -q -b main
  touch "$OVERLAY_DIR/.keep"
  git -C "$OVERLAY_DIR" add .keep
  git -C "$OVERLAY_DIR" commit -q -m "seed"
  git -C "$OVERLAY_DIR" push -q -u origin main

  # Source dir for the sync (irrelevant to this test's assertions, but must
  # exist for the script's copy step not to error).
  SRC_DIR="$BATS_TEST_TMPDIR/claude-src"
  mkdir -p "$SRC_DIR/config"

  export CAST_OVERLAY_REPO="$FAKE_REMOTE"
  export CAST_OVERLAY_DIR="$OVERLAY_DIR"
  export CAST_CLAUDE_DIR="$SRC_DIR"
}

teardown() {
  teardown_temp_home
}

@test "cast-overlay-sync sets correct local git identity on the overlay dir (dry-run)" {
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  local_email="$(git -C "$OVERLAY_DIR" config user.email)"
  local_name="$(git -C "$OVERLAY_DIR" config user.name)"

  [ "$local_email" = "$EXPECTED_EMAIL" ]
  [ "$local_name" = "$EXPECTED_NAME" ]
}

@test "cast-overlay-sync does not touch global git config" {
  # Isolate global config to a throwaway file so we never touch the real
  # user's global git config, then confirm the script left it untouched.
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/fake-gitconfig-global"
  touch "$GIT_CONFIG_GLOBAL"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "should-not-change@example.com"

  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  global_email="$(git config --file "$GIT_CONFIG_GLOBAL" user.email)"
  [ "$global_email" = "should-not-change@example.com" ]
}

@test "cast-overlay-sync corrects a pre-existing real-email local config (regression for GH007)" {
  # Pre-condition sanity check: setup() seeded the real (buggy) identity.
  pre_email="$(git -C "$OVERLAY_DIR" config user.email)"
  [ "$pre_email" = "test-real-address@example.com" ]

  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]

  post_email="$(git -C "$OVERLAY_DIR" config user.email)"
  [ "$post_email" = "$EXPECTED_EMAIL" ]
}
