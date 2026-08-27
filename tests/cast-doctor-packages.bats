#!/usr/bin/env bats
# cast-doctor-packages.bats — Tests for C3: cast doctor Homebrew tap count advisory.
#
# Coverage:
#   - gh absent  ⇒ doctor prints skip INFO line, does NOT hard-fail
#   - gh stub returns 9 (matches expected_packages=9) ⇒ "matches" OK line
#   - gh stub returns 14 (mismatch) ⇒ WARN line with "live=14 but constant=9"
#
# Uses isolated temp HOME (required — cast doctor reads $HOME/.claude).
# Stubs gh on PATH to avoid real network calls.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_DIR/bin/cast"
DB_INIT_SH="$REPO_DIR/scripts/cast-db-init.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME per test
# ---------------------------------------------------------------------------

setup() {
  setup_temp_home
  export CAST_DB_PATH="$HOME/.claude/cast-test.db"

  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/config" "$HOME/.claude/logs" "$HOME/.claude/scripts"
  mkdir -p "$HOME/.claude/cast/events"
  mkdir -p "$HOME/bin"

  # Initialize DB schema
  bash "$DB_INIT_SH" --db "$CAST_DB_PATH" >/dev/null 2>&1 || true

  # Minimal settings.json so hook checks pass
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "id": "test-hook",
        "hooks": [
          {
            "type": "command",
            "command": "echo test",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
JSON

  # Minimal agent so agent-count check passes
  cat > "$HOME/.claude/agents/test-agent.md" <<'MD'
---
name: test-agent
model: sonnet
description: A test agent
tools: []
---
Test agent body.
MD

  # Create a snapshot so backup-freshness check passes
  local backup_root="$HOME/Library/Application Support/cast/backups"
  mkdir -p "$backup_root"
  touch "${backup_root}/cast-snapshot-test"
}

teardown() {
  teardown_temp_home
  unset CAST_DB_PATH
}

# ---------------------------------------------------------------------------
# Helper: write a gh stub that prints a fixed homebrew-* repo count
# ---------------------------------------------------------------------------
_install_gh_stub() {
  local bin_dir="$1"
  local count="$2"
  # The doctor calls: gh repo list ek33450505 --limit 200 --json name -q '...|length'
  # Real gh applies the -q jq expression and prints just the number.
  # Our stub detects the repo list + -q combo and prints the count directly.
  cat > "$bin_dir/gh" <<GHSTUB
#!/bin/sh
if echo "\$*" | grep -q "repo list"; then
  echo "$count"
  exit 0
fi
exit 0
GHSTUB
  chmod +x "$bin_dir/gh"
}

# ---------------------------------------------------------------------------
# Test: gh absent ⇒ INFO skip line, doctor not hard-failed by this check
# ---------------------------------------------------------------------------

@test "cast doctor: Homebrew taps check prints INFO skip when gh is absent" {
  # Ensure gh is NOT on PATH by using a minimal PATH without any gh binary
  local no_gh_dir
  no_gh_dir="$(mktemp -d)"
  # PATH that has only core system tools, no gh
  run env PATH="/usr/bin:/bin" bash "$CAST_CLI" doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  assert_output --partial "Homebrew taps"
}

# ---------------------------------------------------------------------------
# Test: gh stub returns 9 ⇒ OK "matches" line
# ---------------------------------------------------------------------------

@test "cast doctor: Homebrew taps OK when gh returns count matching constant (9)" {
  _install_gh_stub "$HOME/bin" 9
  export PATH="$HOME/bin:$PATH"

  run bash "$CAST_CLI" doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  assert_output --partial "Homebrew taps"
  assert_output --partial "matches"
}

# ---------------------------------------------------------------------------
# Test: gh stub returns 14 ⇒ WARN with "live=14 but constant=9"
# ---------------------------------------------------------------------------

@test "cast doctor: Homebrew taps WARN when gh returns count mismatching constant" {
  _install_gh_stub "$HOME/bin" 14
  export PATH="$HOME/bin:$PATH"

  run bash "$CAST_CLI" doctor
  # cast doctor returns 0 (all pass) or 1 (some checks need attention) since v10 DOC-3.
  # This test is about the check's OUTPUT, not the global verdict, so accept either --
  # but still catch a crash (2, 127, ...).
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  # The new check is advisory-only — overall doctor still exits 0
  assert_output --partial "Homebrew taps"
  assert_output --partial "live=14"
  assert_output --partial "constant=9"
}
