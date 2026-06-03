#!/usr/bin/env bats

# Tests for scripts/cast-overlay-sync.sh
# All tests use isolated temp dirs and a real git repo (not mocks).
# HARD RULE: never touch the real repo or $HOME.

setup() {
  # Create isolated directories
  BATS_OVERLAY_DIR="$BATS_TEST_TMPDIR/overlay"
  BATS_CLAUDE_DIR="$BATS_TEST_TMPDIR/dot-claude"
  BATS_HOME="$BATS_TEST_TMPDIR/home"
  BATS_OVERLAY_SOURCE="$BATS_TEST_TMPDIR/overlay-source"

  mkdir -p "$BATS_CLAUDE_DIR"
  mkdir -p "$BATS_HOME"
  mkdir -p "$BATS_HOME/.claude/logs"
  mkdir -p "$BATS_OVERLAY_SOURCE"

  # Seed BATS_CLAUDE_DIR with test files
  mkdir -p "$BATS_CLAUDE_DIR/config"
  mkdir -p "$BATS_CLAUDE_DIR/rules"
  mkdir -p "$BATS_CLAUDE_DIR/agent-memory-local"

  echo "pii_patterns:" > "$BATS_CLAUDE_DIR/config/pii-denylist-local.txt"
  echo "# Test rule" > "$BATS_CLAUDE_DIR/rules/a.md"
  echo "# CLAUDE.md" > "$BATS_CLAUDE_DIR/CLAUDE.md"
  echo "memory_entry" > "$BATS_CLAUDE_DIR/agent-memory-local/test.md"

  # Initialize the overlay source as a bare git repo
  cd "$BATS_OVERLAY_SOURCE"
  git init -q --bare
  cd - >/dev/null

  # Resolve the repo directory
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # Export isolated HOME and env vars
  export HOME="$BATS_HOME"
  export CAST_OVERLAY_DIR="$BATS_OVERLAY_DIR"
  export CAST_CLAUDE_DIR="$BATS_CLAUDE_DIR"
  export CAST_OVERLAY_REPO="$BATS_OVERLAY_SOURCE"
}

teardown() {
  # Cleanup handled by BATS_TEST_TMPDIR
  unset HOME CAST_OVERLAY_DIR CAST_CLAUDE_DIR CAST_OVERLAY_REPO
}

@test "CLAUDE_SUBPROCESS guard: exits 0 immediately without cloning" {
  # Set the guard variable
  export CLAUDE_SUBPROCESS=1

  # Overlay dir should NOT exist yet
  [ ! -d "$BATS_OVERLAY_DIR" ]

  run bash "$REPO_DIR/scripts/cast-overlay-sync.sh" --dry-run

  # Should exit 0
  [ "$status" -eq 0 ]

  # Overlay dir should still NOT exist (script never ran the clone)
  [ ! -d "$BATS_OVERLAY_DIR" ]
}

@test "dry-run stages files but does not commit" {
  # Unset CLAUDE_SUBPROCESS (allow script to run)
  unset CLAUDE_SUBPROCESS

  # Create initial commit in source repo using file:// URL
  TEMP_CLONE="$BATS_TEST_TMPDIR/init-clone"
  mkdir -p "$TEMP_CLONE"
  cd "$TEMP_CLONE"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  touch README.md
  git add README.md
  git commit -q -m "initial"

  # Set overlay source to this repo (use file:// URL)
  export CAST_OVERLAY_REPO="file://$TEMP_CLONE"
  cd - >/dev/null

  # Run with --dry-run
  run bash "$REPO_DIR/scripts/cast-overlay-sync.sh" --dry-run

  [ "$status" -eq 0 ]

  # Verify overlay dir was cloned
  [ -d "$BATS_OVERLAY_DIR" ]

  # Verify only the initial commit exists (no new commit from dry-run)
  cd "$BATS_OVERLAY_DIR"
  COMMIT_COUNT=$(git rev-list --all --count)
  cd - >/dev/null
  [ "$COMMIT_COUNT" -eq 1 ]

  rm -rf "$TEMP_CLONE"
}

@test "secret content in staged files aborts commit" {
  unset CLAUDE_SUBPROCESS

  # Create initial commit in source repo
  TEMP_CLONE="$BATS_TEST_TMPDIR/init-clone-2"
  mkdir -p "$TEMP_CLONE"
  cd "$TEMP_CLONE"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  touch README.md
  git add README.md
  git commit -q -m "initial"

  export CAST_OVERLAY_REPO="file://$TEMP_CLONE"
  cd - >/dev/null

  # Add a file with secret content to CAST_CLAUDE_DIR.
  # Must be a path the script actually backs up — root settings.local.json (the realistic risk file).
  # (config/settings.local.json is NOT in the copy set, so planting it there would be silently ignored.)
  echo '{"api_key":"sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWX1234"}' > "$BATS_CLAUDE_DIR/settings.local.json"

  # Run script (should detect secret and abort)
  run bash "$REPO_DIR/scripts/cast-overlay-sync.sh"

  # Should fail with exit code 1
  [ "$status" -eq 1 ]

  # Output should mention secret detection
  [[ "$output" =~ "Secret pattern detected" ]]

  rm -rf "$TEMP_CLONE"
}

@test "clean run with no changes exits 0" {
  unset CLAUDE_SUBPROCESS

  # Create initial commit in source repo
  TEMP_CLONE="$BATS_TEST_TMPDIR/init-clone-3"
  mkdir -p "$TEMP_CLONE"
  cd "$TEMP_CLONE"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  touch README.md
  git add README.md
  git commit -q -m "initial"

  export CAST_OVERLAY_REPO="file://$TEMP_CLONE"
  cd - >/dev/null

  # Run once to populate overlay with --dry-run
  run bash "$REPO_DIR/scripts/cast-overlay-sync.sh" --dry-run
  [ "$status" -eq 0 ]

  # Now run again with --dry-run
  # Since no changes to CAST_CLAUDE_DIR since last run, should report "nothing to commit"
  run bash "$REPO_DIR/scripts/cast-overlay-sync.sh" --dry-run
  [ "$status" -eq 0 ]

  rm -rf "$TEMP_CLONE"
}
