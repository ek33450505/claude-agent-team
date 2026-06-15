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
  [ -d "$HOME/.claude/backups" ]
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
