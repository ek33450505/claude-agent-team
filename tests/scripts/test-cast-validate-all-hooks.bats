#!/usr/bin/env bats
# tests/scripts/test-cast-validate-all-hooks.bats
# Test the --source and --runtime flag behavior (Task C2 — flag rename)
#
# IMPORTANT: this test must NEVER touch the real repo's settings.json or
# ~/.claude/settings.json. Earlier draft of this test rm -f'd $REPO_ROOT/settings.json
# during the --source case and deleted live data. We sandbox via a tempdir
# repo + tempdir HOME for every assertion.

setup() {
  REAL_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export SANDBOX="$(mktemp -d)"
  export TEST_REPO="$SANDBOX/repo"
  export TEST_HOME="$SANDBOX/home"

  mkdir -p "$TEST_REPO/scripts" "$TEST_HOME/.claude"

  # Copy validator + its dependency into the sandbox repo
  cp "$REAL_REPO/scripts/cast-validate-all-hooks.sh" "$TEST_REPO/scripts/"
  cp "$REAL_REPO/scripts/cast-validate-hook-contracts.sh" "$TEST_REPO/scripts/" 2>/dev/null || true

  # Sandbox runtime hook + settings
  cat > "$TEST_HOME/.claude/test-runtime-hook.sh" <<'SH'
#!/usr/bin/env bash
echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "[test-runtime]"}}'
SH
  chmod +x "$TEST_HOME/.claude/test-runtime-hook.sh"

  cat > "$TEST_HOME/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash $TEST_HOME/.claude/test-runtime-hook.sh" }
        ]
      }
    ]
  }
}
JSON

  # Sandbox source hook + settings (sits under TEST_REPO, not REAL_REPO)
  cat > "$TEST_REPO/scripts/test-source-hook.sh" <<'SH'
#!/usr/bin/env bash
echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "[test-source]"}}'
SH
  chmod +x "$TEST_REPO/scripts/test-source-hook.sh"

  cat > "$TEST_REPO/settings.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash $TEST_REPO/scripts/test-source-hook.sh" }
        ]
      }
    ]
  }
}
JSON
}

teardown() {
  rm -rf "$SANDBOX"
}

@test "no flag: uses runtime settings (backward compat)" {
  HOME="$TEST_HOME" run bash "$TEST_REPO/scripts/cast-validate-all-hooks.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated 1 hooks"* ]]
}

@test "--runtime flag: reads \$HOME/.claude/settings.json" {
  HOME="$TEST_HOME" run bash "$TEST_REPO/scripts/cast-validate-all-hooks.sh" --runtime
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated 1 hooks"* ]]
}

@test "--source flag: reads repo settings.json (sandbox repo, not real repo)" {
  HOME="$TEST_HOME" run bash "$TEST_REPO/scripts/cast-validate-all-hooks.sh" --source
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated 1 hooks"* ]]
}

@test "--help flag: displays usage with both flags documented" {
  run bash "$TEST_REPO/scripts/cast-validate-all-hooks.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--runtime"* ]]
  [[ "$output" == *"--source"* ]]
}

@test "real repo settings.json is untouched after running tests" {
  # Sentinel: if any test deletes the real settings.json, this fails.
  [ -f "$REAL_REPO/settings.json" ]
}
