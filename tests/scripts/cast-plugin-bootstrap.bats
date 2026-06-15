#!/usr/bin/env bats
# Tests for scripts/cast-plugin-bootstrap.sh
# SessionStart hook that initializes CAST runtime dirs and symlinks plugin scripts.
# Uses isolated temp HOME to avoid writing to real ~/.claude.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  load '../helpers/setup'
  setup_temp_home

  # Create an isolated plugin root with stub scripts
  export CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/pluginroot"
  mkdir -p "$CLAUDE_PLUGIN_ROOT/scripts"

  # Create two stub scripts in the fake plugin
  printf '#!/usr/bin/env bash\n' > "$CLAUDE_PLUGIN_ROOT/scripts/stub-a.sh"
  chmod +x "$CLAUDE_PLUGIN_ROOT/scripts/stub-a.sh"
  printf '#!/usr/bin/env bash\n' > "$CLAUDE_PLUGIN_ROOT/scripts/stub-b.sh"
  chmod +x "$CLAUDE_PLUGIN_ROOT/scripts/stub-b.sh"

  # Set up the DB path
  export CAST_DB_PATH="$HOME/.claude/cast.db"

  # PATH-shim osascript, open, notify-send, terminal-notifier to no-ops
  # (bootstrap doesn't call these, but be defensive)
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for cmd in osascript open notify-send terminal-notifier; do
    printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$cmd"
    chmod +x "$BATS_TEST_TMPDIR/bin/$cmd"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
  teardown_temp_home
}

@test "cast-plugin-bootstrap.sh exits 0" {
  run bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"
  assert_success
}

@test "cast-plugin-bootstrap.sh creates required CAST runtime directories" {
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  [ -d "$HOME/.claude/scripts" ]
  [ -d "$HOME/.claude/logs" ]
  [ -d "$HOME/.claude/agent-memory-local" ]
  [ -d "$HOME/.claude/cast/events" ]
  [ -d "$HOME/.claude/agent-status" ]
  [ -d "$HOME/.claude/plans" ]
  [ -d "$HOME/.claude/briefings" ]
  [ -d "$HOME/.claude/reports" ]
  [ -d "$HOME/.claude/cast/state" ]
  [ -d "$HOME/.claude/cast/offline-queue" ]
  [ -d "$HOME/.claude/cast/reviews" ]
  [ -d "$HOME/.claude/cast/artifacts" ]
  [ -d "$HOME/.claude/config" ]
}

@test "cast-plugin-bootstrap.sh symlinks plugin scripts into ~/.claude/scripts/" {
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # Check that both stub scripts are symlinked
  [ -L "$HOME/.claude/scripts/stub-a.sh" ]
  [ -L "$HOME/.claude/scripts/stub-b.sh" ]
  [ -e "$HOME/.claude/scripts/stub-a.sh" ]
  [ -e "$HOME/.claude/scripts/stub-b.sh" ]
}

@test "cast-plugin-bootstrap.sh is idempotent (run twice succeeds)" {
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"
  # Verify first run created the symlinks
  [ -L "$HOME/.claude/scripts/stub-a.sh" ]

  # Run a second time
  run bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"
  assert_success

  # Symlinks should still be valid
  [ -L "$HOME/.claude/scripts/stub-a.sh" ]
  [ -e "$HOME/.claude/scripts/stub-a.sh" ]
}

@test "cast-plugin-bootstrap.sh does not overwrite existing non-symlink files" {
  # Pre-create a real file (non-symlink) in ~/.claude/scripts/keep.sh
  mkdir -p "$HOME/.claude/scripts"
  printf 'KEEP-ME' > "$HOME/.claude/scripts/keep.sh"
  original_content=$(cat "$HOME/.claude/scripts/keep.sh")

  # Also create the stub in the plugin
  printf '#!/usr/bin/env bash\n' > "$CLAUDE_PLUGIN_ROOT/scripts/keep.sh"

  # Run bootstrap
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # The original file should still exist and not be a symlink
  [ -f "$HOME/.claude/scripts/keep.sh" ]
  [ ! -L "$HOME/.claude/scripts/keep.sh" ]
  [ "$(cat "$HOME/.claude/scripts/keep.sh")" = "$original_content" ]
}

@test "cast-plugin-bootstrap.sh symlinks point to the correct plugin scripts directory" {
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # Verify that the symlink target is correct
  link_target=$(readlink "$HOME/.claude/scripts/stub-a.sh")
  [ "$link_target" = "$CLAUDE_PLUGIN_ROOT/scripts/stub-a.sh" ]
}

@test "cast-plugin-bootstrap.sh prunes broken symlink pointing INTO plugin scripts dir" {
  # Pre-create ~/.claude/scripts directory
  mkdir -p "$HOME/.claude/scripts"

  # Create a broken symlink pointing INTO the plugin scripts dir
  # The target should be non-existent
  ln -s "$CLAUDE_PLUGIN_ROOT/scripts/nonexistent-script.sh" "$HOME/.claude/scripts/broken-into-plugin.sh"

  # Verify it's a broken symlink before bootstrap
  [ -L "$HOME/.claude/scripts/broken-into-plugin.sh" ]
  [ ! -e "$HOME/.claude/scripts/broken-into-plugin.sh" ]

  # Run bootstrap
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # The broken symlink should be removed
  [ ! -e "$HOME/.claude/scripts/broken-into-plugin.sh" ]
  [ ! -L "$HOME/.claude/scripts/broken-into-plugin.sh" ]
}

@test "cast-plugin-bootstrap.sh preserves valid (non-broken) symlinks" {
  # Pre-create ~/.claude/scripts directory
  mkdir -p "$HOME/.claude/scripts"

  # Create a valid external script and symlink to it
  external_script="$BATS_TEST_TMPDIR/external-script.sh"
  printf '#!/usr/bin/env bash\n' > "$external_script"
  chmod +x "$external_script"

  ln -s "$external_script" "$HOME/.claude/scripts/valid-symlink.sh"

  # Verify it's a valid symlink before bootstrap
  [ -L "$HOME/.claude/scripts/valid-symlink.sh" ]
  [ -e "$HOME/.claude/scripts/valid-symlink.sh" ]

  # Run bootstrap
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # The valid symlink should still exist
  [ -L "$HOME/.claude/scripts/valid-symlink.sh" ]
  [ -e "$HOME/.claude/scripts/valid-symlink.sh" ]
  target=$(readlink "$HOME/.claude/scripts/valid-symlink.sh")
  [ "$target" = "$external_script" ]
}

@test "cast-plugin-bootstrap.sh does NOT prune broken symlink pointing OUTSIDE plugin dir (safety guard)" {
  # Pre-create ~/.claude/scripts directory
  mkdir -p "$HOME/.claude/scripts"

  # Create a broken symlink pointing OUTSIDE the plugin scripts dir
  ln -s "/tmp/nonexistent-outside-plugin/script.sh" "$HOME/.claude/scripts/broken-outside-plugin.sh"

  # Verify it's a broken symlink before bootstrap
  [ -L "$HOME/.claude/scripts/broken-outside-plugin.sh" ]
  [ ! -e "$HOME/.claude/scripts/broken-outside-plugin.sh" ]

  # Run bootstrap
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # The broken symlink pointing outside should NOT be removed (safety guard)
  [ -L "$HOME/.claude/scripts/broken-outside-plugin.sh" ]
  [ ! -e "$HOME/.claude/scripts/broken-outside-plugin.sh" ]
}

@test "cast-plugin-bootstrap.sh leaves real (non-symlink) files untouched" {
  # Pre-create ~/.claude/scripts directory
  mkdir -p "$HOME/.claude/scripts"

  # Create a real file (non-symlink) in ~/.claude/scripts/
  real_file="$HOME/.claude/scripts/real-file.sh"
  printf '#!/usr/bin/env bash\necho REAL\n' > "$real_file"
  chmod +x "$real_file"

  original_content=$(cat "$real_file")

  # Run bootstrap
  bash "$REPO_DIR/scripts/cast-plugin-bootstrap.sh"

  # The real file should still exist, be unchanged, and remain a real file (not a symlink)
  [ -f "$real_file" ]
  [ ! -L "$real_file" ]
  [ "$(cat "$real_file")" = "$original_content" ]
}
