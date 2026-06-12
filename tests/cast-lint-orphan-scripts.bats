#!/usr/bin/env bats
# Regression test for cast-lint-orphan-scripts.py
#
# Root cause guarded: the lint previously resolved ~/.claude/scripts/X.sh
# against the LIVE installed path rather than the repo's scripts/ directory.
# After PRs #195/#196 merged (adding/changing scripts) without install.sh
# being re-run, ~/.claude/scripts/ was absent and all 26 hook references
# were falsely reported as missing.
#
# Fix: ~/.claude/scripts/X.sh is now resolved to repo_root/scripts/X.sh,
# making the check hermetic (independent of install.sh state).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINT_PY="$REPO_DIR/scripts/cast-lint-orphan-scripts.py"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp HOME + fake git repo per test
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"   # isolate: real ~/.claude/scripts/ must not interfere
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO/scripts"
  git -C "$FAKE_REPO" init -q
  git -C "$FAKE_REPO" config user.email "test@example.com"
  git -C "$FAKE_REPO" config user.name "CAST Test"
}

teardown() {
  rm -rf "$FAKE_REPO"
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
}

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

_write_settings() {
  # Usage: _write_settings "bash ~/.claude/scripts/hook.sh"
  local cmd="$1"
  printf '{"hooks":{"PreToolUse":[{"command":"%s"}]}}\n' "$cmd" \
    > "$FAKE_REPO/settings.json"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "exit 0 when no settings.json present" {
  # No settings.json in fake repo — lint should warn and return 0
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_success
}

@test "exit 0 when tilde-script reference exists in repo scripts/" {
  # This is the regression case: script lives in repo/scripts/ but NOT in
  # ~/.claude/scripts/ (which is absent in our isolated HOME).
  # Before the fix: exit 1 (checked live path). After the fix: exit 0.
  _write_settings "bash ~/.claude/scripts/cast-headless-guard.sh"
  touch "$FAKE_REPO/scripts/cast-headless-guard.sh"
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_success
}

@test "exit 1 when tilde-script reference is missing from repo scripts/" {
  # Genuine orphan: settings.json references a script that doesn't exist anywhere.
  # Both pre- and post-fix, this must fail — the gate must not be weakened.
  _write_settings "bash ~/.claude/scripts/totally-nonexistent-hook.sh"
  # Do NOT create the script in fake_repo/scripts/
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_failure
  assert_output --partial "totally-nonexistent-hook.sh"
}

@test "exit 0 when bare scripts/ reference exists in repo" {
  _write_settings "bash scripts/some-helper.sh"
  touch "$FAKE_REPO/scripts/some-helper.sh"
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_success
}

@test "exit 1 when bare scripts/ reference is missing from repo" {
  _write_settings "bash scripts/ghost-script.sh"
  # Do NOT create the script
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_failure
  assert_output --partial "ghost-script.sh"
}

@test "exit 1 when settings.json references an absolute path (contract violation)" {
  # Absolute paths bypass repo_root resolution and would silently consult the live
  # filesystem — the exact bug class the ~/ fix addressed. They are invalid in a
  # hermetic repo lint regardless of whether the file exists on disk.
  _write_settings "bash /usr/local/bin/some-script.sh"
  # Even if the file exists on the host, the lint must reject it
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_failure
  assert_output --partial "absolute path"
}

@test "exit 0 when settings.json has no hook commands" {
  printf '{"permissions":{"allow":["Bash"]}}\n' > "$FAKE_REPO/settings.json"
  run bash -c "cd '$FAKE_REPO' && python3 '$LINT_PY' 2>&1"
  assert_success
}
