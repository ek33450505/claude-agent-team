#!/usr/bin/env bats
# Tests for scripts/cast-plan-resume-hook.sh
#
# Coverage:
#   - CLAUDE_SUBPROCESS guard (early exit)
#   - Marker absence → silent exit
#   - Marker present → calls cast-plan-doctor.py --resume
#   - JSON output structure (hookSpecificOutput, hookEventName)
#   - Nonexistent marker path → silent exit

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="${REPO}/scripts/cast-plan-resume-hook.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown — isolated temp home per test
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/config" "$HOME/.claude/logs"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Test 1: CLAUDE_SUBPROCESS=1 → exit 0, empty output
# ---------------------------------------------------------------------------

@test "plan-resume-hook: CLAUDE_SUBPROCESS=1 exits 0 silent" {
  run env CLAUDE_SUBPROCESS=1 bash "$HOOK" <<< '{}'
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 2: No marker file → exit 0, empty output
# ---------------------------------------------------------------------------

@test "plan-resume-hook: no marker exits 0 silent" {
  # temp HOME has no ~/.claude/config/active-plan
  run bash "$HOOK" <<< '{}'
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 3: Marker points to nonexistent plan → exit 0, empty output
# ---------------------------------------------------------------------------

@test "plan-resume-hook: marker to nonexistent path exits 0 silent" {
  printf '%s\n' "/tmp/does-not-exist-xyz-9999.md" > "$HOME/.claude/config/active-plan"
  run bash "$HOOK" <<< '{}'
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 4: Marker present, points to real repo plan
# ---------------------------------------------------------------------------

@test "plan-resume-hook: marker to real plan exits 0 with JSON" {
  # Point to the real repo plan (verified to exist)
  local plan_path="$REPO/plans/cast-v9-foundation.md"
  if [[ ! -f "$plan_path" ]]; then
    skip "repo plan absent: $plan_path"
  fi

  printf '%s\n' "$plan_path" > "$HOME/.claude/config/active-plan"

  run bash "$HOOK" <<< '{}'
  assert_success

  # Save output to temp file to avoid quoting issues
  local json_file
  json_file="$BATS_TMPDIR/hook-output.json"
  printf '%s\n' "$output" > "$json_file"

  # Output must be valid JSON
  run python3 -c "import json; json.load(open('$json_file'))"
  assert_success

  # Verify hookEventName = SessionStart
  run python3 -c "import json; data = json.load(open('$json_file')); assert data['hookSpecificOutput']['hookEventName'] == 'SessionStart'"
  assert_success

  # Verify additionalContext contains plan-resume marker
  run python3 -c "import json; data = json.load(open('$json_file')); assert '<plan-resume' in data['hookSpecificOutput']['additionalContext']"
  assert_success
}

# ---------------------------------------------------------------------------
# Test 5: Marker file empty → exit 0, empty output
# ---------------------------------------------------------------------------

@test "plan-resume-hook: empty marker file exits 0 silent" {
  touch "$HOME/.claude/config/active-plan"
  run bash "$HOOK" <<< '{}'
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 6: Marker file with only whitespace → exit 0, empty output
# ---------------------------------------------------------------------------

@test "plan-resume-hook: whitespace-only marker exits 0 silent" {
  printf '   \n' > "$HOME/.claude/config/active-plan"
  run bash "$HOOK" <<< '{}'
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# Test 7: Real plan marker → systemMessage contains orientation
# ---------------------------------------------------------------------------

@test "plan-resume-hook: JSON output includes systemMessage" {
  local plan_path="$REPO/plans/cast-v9-foundation.md"
  if [[ ! -f "$plan_path" ]]; then
    skip "repo plan absent: $plan_path"
  fi

  printf '%s\n' "$plan_path" > "$HOME/.claude/config/active-plan"

  run bash "$HOOK" <<< '{}'
  assert_success

  # Save output to temp file to avoid quoting issues
  local json_file
  json_file="$BATS_TMPDIR/hook-output-msg.json"
  printf '%s\n' "$output" > "$json_file"

  # systemMessage must be present and non-empty
  run python3 -c "import json; data = json.load(open('$json_file')); msg = data.get('systemMessage', ''); assert msg and len(msg) > 0, 'systemMessage empty or missing'"
  assert_success
}
