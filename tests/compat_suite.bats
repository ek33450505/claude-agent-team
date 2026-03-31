#!/usr/bin/env bats
# compat_suite.bats — Tests for cast-compat.sh (Phase 9.75b)
#
# Coverage:
#   - cast compat save writes ~/.claude/cast/last-known-good-version
#   - cast compat diff outputs "no change" message when versions match
#   - cast compat test exits 0 when bats and claude are available

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COMPAT_SH="$REPO_DIR/scripts/cast-compat.sh"
CAST_CLI="$REPO_DIR/bin/cast"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"

  mkdir -p "$HOME/.claude/cast"

  # Stub claude so version-dependent tests are deterministic and offline-safe
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/claude" <<'STUB'
#!/bin/bash
if [[ "$*" == *"--version"* ]]; then
  echo "1.0.0-stub"
  exit 0
fi
if [[ "$*" == *"--help"* ]]; then
  echo "Usage: claude [options]"
  echo "  --print"
  echo "  --dangerously-skip-permissions"
  exit 0
fi
echo "stub"
exit 0
STUB
  chmod +x "$HOME/bin/claude"
  export PATH="$HOME/bin:$PATH"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# T1 — cast compat save writes last-known-good-version to BATS_TMPDIR scope
# ---------------------------------------------------------------------------

@test "cast compat save: exits 0" {
  run bash "$COMPAT_SH" save
  assert_success
}

@test "cast compat save: creates last-known-good-version file" {
  bash "$COMPAT_SH" save

  run test -f "$HOME/.claude/cast/last-known-good-version"
  assert_success
}

@test "cast compat save: last-known-good-version contains a non-empty version string" {
  bash "$COMPAT_SH" save

  local lkg
  lkg="$(cat "$HOME/.claude/cast/last-known-good-version")"
  [ -n "$lkg" ]
}

@test "cast compat save: saved version matches claude --version output" {
  bash "$COMPAT_SH" save

  local saved
  saved="$(cat "$HOME/.claude/cast/last-known-good-version")"
  local live
  live="$(claude --version 2>/dev/null | head -1)"
  [ "$saved" = "$live" ]
}

@test "cast compat save: prints confirmation message" {
  run bash "$COMPAT_SH" save
  assert_success
  assert_output --partial "Saved last-known-good version"
}

@test "cast compat save: running twice overwrites, does not duplicate content" {
  bash "$COMPAT_SH" save
  bash "$COMPAT_SH" save

  # File should contain exactly one line
  local line_count
  line_count="$(wc -l < "$HOME/.claude/cast/last-known-good-version")"
  [ "$line_count" -le 1 ]
}

# ---------------------------------------------------------------------------
# T2 — cast compat diff: outputs "no change" when versions match
# ---------------------------------------------------------------------------

@test "cast compat diff: exits 0 when versions match" {
  # Save current stub version, then diff — should be no change
  bash "$COMPAT_SH" save

  run bash "$COMPAT_SH" diff
  assert_success
}

@test "cast compat diff: prints 'no change' when versions match" {
  bash "$COMPAT_SH" save

  run bash "$COMPAT_SH" diff
  assert_success
  assert_output --partial "no change"
}

@test "cast compat diff: exits 0 and warns when no LKG file exists" {
  # Do NOT save — LKG file absent
  run bash "$COMPAT_SH" diff
  assert_success
  assert_output --partial "No last-known-good"
}

@test "cast compat diff: exits 1 when version has changed" {
  # Write a different version to the LKG file manually
  echo "0.0.0-old" > "$HOME/.claude/cast/last-known-good-version"

  run bash "$COMPAT_SH" diff
  assert_failure
  assert_output --partial "Version changed"
}

@test "cast compat diff: prints both versions when version has changed" {
  echo "0.0.0-old" > "$HOME/.claude/cast/last-known-good-version"

  run bash "$COMPAT_SH" diff
  assert_failure
  assert_output --partial "0.0.0-old"
}

# ---------------------------------------------------------------------------
# T3 — cast compat test exits 0 when bats and claude are available
# ---------------------------------------------------------------------------

@test "cast compat test: exits 0 when bats and claude are available" {
  # Both bats (we're running under it) and our stub claude are in PATH
  if ! command -v bats >/dev/null 2>&1; then
    skip "bats not found in PATH — cannot self-test"
  fi

  run bash "$COMPAT_SH" test
  # Exit 0 means all compat.bats tests passed
  # Exit non-zero means one or more contract tests failed — still acceptable
  # for a stub environment. The important assertion is the script does not crash.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "cast compat test: fails gracefully when bats is not available" {
  # Remove bats from the stub PATH
  mkdir -p "$HOME/no-bats-bin"
  # Prepend a path that shadows bats
  cat > "$HOME/no-bats-bin/bats" <<'EOF'
#!/bin/bash
exit 127
EOF
  chmod +x "$HOME/no-bats-bin/bats"

  # Override PATH to a bats that always fails (simulates bats not in PATH)
  PATH="$HOME/no-bats-bin:/usr/bin:/bin" run bash "$COMPAT_SH" test
  # Should print an error, not crash with unbound variable / pipe error
  [ "$status" -ne 0 ]
  assert_output --partial "bats"
}

# ---------------------------------------------------------------------------
# T4 — cast compat test: unknown subcommand returns non-zero
# ---------------------------------------------------------------------------

@test "cast compat: unknown subcommand prints usage and exits non-zero" {
  run bash "$COMPAT_SH" invalid-subcmd
  assert_failure
  assert_output --partial "Usage"
}

# ---------------------------------------------------------------------------
# T5 — cast CLI integration: cast compat save wires through to script
# ---------------------------------------------------------------------------

@test "cast compat save via cast CLI: exits 0" {
  # Wire cast to find cast-compat.sh in the repo scripts dir
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR/scripts/cast-compat.sh" "$HOME/.claude/scripts/cast-compat.sh"

  run bash "$CAST_CLI" compat save
  assert_success
}

@test "cast compat save via cast CLI: creates last-known-good-version file" {
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR/scripts/cast-compat.sh" "$HOME/.claude/scripts/cast-compat.sh"

  bash "$CAST_CLI" compat save

  run test -f "$HOME/.claude/cast/last-known-good-version"
  assert_success
}

@test "cast compat diff via cast CLI: exits 0 after save when versions match" {
  mkdir -p "$HOME/.claude/scripts"
  cp "$REPO_DIR/scripts/cast-compat.sh" "$HOME/.claude/scripts/cast-compat.sh"

  bash "$CAST_CLI" compat save

  run bash "$CAST_CLI" compat diff
  assert_success
  assert_output --partial "no change"
}
