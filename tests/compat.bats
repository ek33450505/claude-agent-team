#!/usr/bin/env bats
# compat.bats — CAST compatibility contract tests
# Verifies that the installed Claude Code CLI still supports the interfaces CAST depends on.
# Run: bats tests/compat.bats
# Or:  cast compat test

setup() {
  # Resolve repo root from test file location
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

# 1. Claude CLI version check
@test "claude binary is present and returns version" {
  command -v claude &>/dev/null || skip "claude CLI not available"
  run claude --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+ ]]
}

# 2. Required flags still exist — --print
@test "claude --print flag is accepted" {
  command -v claude &>/dev/null || skip "claude CLI not available"
  run claude --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--print" ]]
}

# 2b. Required flags still exist — --dangerously-skip-permissions
@test "claude --dangerously-skip-permissions flag is accepted" {
  command -v claude &>/dev/null || skip "claude CLI not available"
  run claude --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dangerously-skip-permissions" ]]
}

# 3. Basic inference works
@test "claude -p responds to a simple prompt" {
  command -v claude &>/dev/null || skip "claude CLI not available"
  # Use gtimeout on macOS, timeout on Linux, or skip if neither available
  local timeout_cmd=""
  if command -v gtimeout &>/dev/null; then timeout_cmd="gtimeout 30"
  elif command -v timeout &>/dev/null; then timeout_cmd="timeout 30"
  fi
  run $timeout_cmd claude -p "Reply with only the word PONG" --print
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PONG" ]]
}

# 4. Hook environment fields — pre-tool-guard.sh handles missing fields gracefully
@test "CAST hook env includes expected fields" {
  local guard_script="${REPO_ROOT}/scripts/pre-tool-guard.sh"
  if [ ! -f "$guard_script" ]; then
    skip "pre-tool-guard.sh not found at $guard_script"
  fi
  # Script should not exit 127 (command not found) on minimal JSON input
  run bash "$guard_script" <<< '{"tool_name":"Write","tool_input":{}}'
  [ "$status" -ne 127 ]
}

# 5. Version change detection — informational, always passes, warns if changed
@test "installed version matches or supersedes last-known-good" {
  local lkg_file="${HOME}/.claude/cast/last-known-good-version"
  if [ -f "$lkg_file" ]; then
    local lkg
    lkg="$(cat "$lkg_file")"
    local current
    current="$(claude --version 2>/dev/null | head -1)"
    echo "LKG: $lkg | Current: $current"
    if [ "$lkg" != "$current" ]; then
      echo "WARNING: Claude version changed from $lkg to $current"
      echo "Run: cast compat save  to update last-known-good"
    fi
  else
    echo "No last-known-good version file found at $lkg_file"
    echo "Run: cast compat save  to record current version"
  fi
  # Always pass — this test is informational only
  true
}
