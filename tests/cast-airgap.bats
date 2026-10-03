#!/usr/bin/env bats
# Tests for scripts/cast-airgap.sh
#
# Coverage:
#   - Enable/disable air-gap mode
#   - Status checking
#   - Config file management
#   - State file management
#   - Environment variable override
#   - Help output
#   - Invalid argument handling

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="${REPO}/scripts/cast-airgap.sh"

setup() {
  setup_temp_home
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/cast/state"
  # The script's status output honours CAST_AIRGAP=1; an ambient value would
  # make the "OFF" tests pass/fail on the caller's environment, not the script.
  unset CAST_AIRGAP
}

teardown() {
  teardown_temp_home
}

@test "airgap: enable mode creates config with airgap=true" {
  run bash "$SCRIPT" on
  assert_success
  assert_output --partial "CAST-AIRGAP ON"

  [[ -f "$HOME/.claude/config/cast-cli.json" ]]
  grep -q '"airgap": true' "$HOME/.claude/config/cast-cli.json"
}

@test "airgap: enable mode creates state file" {
  bash "$SCRIPT" on > /dev/null

  [[ -f "$HOME/.claude/cast/state/airgap.state" ]]
  [[ "$(cat "$HOME/.claude/cast/state/airgap.state")" == "1" ]]
}

@test "airgap: disable mode updates config with airgap=false" {
  bash "$SCRIPT" on > /dev/null

  run bash "$SCRIPT" off
  assert_success
  assert_output --partial "CAST-AIRGAP OFF"

  grep -q '"airgap": false' "$HOME/.claude/config/cast-cli.json"
}

@test "airgap: disable mode removes state file" {
  bash "$SCRIPT" on > /dev/null
  bash "$SCRIPT" off > /dev/null

  [[ ! -f "$HOME/.claude/cast/state/airgap.state" ]]
}

@test "airgap: status shows ON when airgap=true" {
  bash "$SCRIPT" on > /dev/null

  run bash "$SCRIPT" status
  assert_success
  assert_output --partial "AIRGAP: ON"
}

@test "airgap: status shows OFF when airgap=false" {
  run bash "$SCRIPT" status
  assert_success
  assert_output --partial "AIRGAP: OFF"
}

@test "airgap: default command is status" {
  run bash "$SCRIPT"
  assert_success
  assert_output --partial "AIRGAP:"
}

@test "airgap: help flag displays usage" {
  run bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: cast-airgap.sh <on|off|status>"
  assert_output --partial "on      Enable air-gap mode"
  assert_output --partial "off     Disable air-gap mode"
  assert_output --partial "status  Print current air-gap state"
}

@test "airgap: -h flag displays usage" {
  run bash "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "airgap: invalid argument returns error" {
  run bash "$SCRIPT" invalid
  assert_failure
  assert_output --partial "Error: Unknown argument"
}

@test "airgap: config file is valid JSON" {
  bash "$SCRIPT" on > /dev/null

  python3 -m json.tool "$HOME/.claude/config/cast-cli.json" > /dev/null
}

@test "airgap: CAST_AIRGAP=1 env var overrides config" {
  CAST_AIRGAP=1 run bash "$SCRIPT" status
  assert_success
  assert_output --partial "AIRGAP: ON"
}

@test "airgap: config persists other keys when enabling" {
  cat > "$HOME/.claude/config/cast-cli.json" <<'EOF'
{
  "other_setting": "value"
}
EOF

  bash "$SCRIPT" on > /dev/null

  grep -q '"other_setting"' "$HOME/.claude/config/cast-cli.json"
  grep -q '"airgap": true' "$HOME/.claude/config/cast-cli.json"
}

@test "airgap: multiple on commands are idempotent" {
  bash "$SCRIPT" on > /dev/null
  local config1
  config1=$(cat "$HOME/.claude/config/cast-cli.json")

  bash "$SCRIPT" on > /dev/null
  local config2
  config2=$(cat "$HOME/.claude/config/cast-cli.json")

  [[ "$config1" == "$config2" ]]
}

@test "airgap: toggle on/off/on preserves JSON validity" {
  bash "$SCRIPT" on > /dev/null
  python3 -m json.tool "$HOME/.claude/config/cast-cli.json" > /dev/null

  bash "$SCRIPT" off > /dev/null
  python3 -m json.tool "$HOME/.claude/config/cast-cli.json" > /dev/null

  bash "$SCRIPT" on > /dev/null
  python3 -m json.tool "$HOME/.claude/config/cast-cli.json" > /dev/null
}

@test "airgap: status with invalid JSON defaults to OFF" {
  echo "{ invalid" > "$HOME/.claude/config/cast-cli.json"

  run bash "$SCRIPT" status
  assert_success
  assert_output --partial "AIRGAP: OFF"
}

@test "airgap: creates config directory path if missing" {
  # Destructive op: only ever against the sentinel-marked temp HOME.
  [[ -f "$HOME/.cast-test-home" ]]
  rm -rf "$HOME/.claude/cast/state"
  [[ ! -d "$HOME/.claude/cast/state" ]]

  bash "$SCRIPT" on > /dev/null

  [[ -d "$HOME/.claude/cast/state" ]]
  [[ -f "$HOME/.claude/cast/state/airgap.state" ]]
}

@test "airgap: config file ends with newline" {
  bash "$SCRIPT" on > /dev/null

  [[ "$(tail -c 1 "$HOME/.claude/config/cast-cli.json" | od -An -tx1)" == *"0a"* ]]
}

@test "airgap: status output contains rewrite destination" {
  bash "$SCRIPT" on > /dev/null

  run bash "$SCRIPT" status
  assert_success
  assert_output --partial "local:qwen3:8b"
}
