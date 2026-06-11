#!/usr/bin/env bats
# tests/scripts/cast-cwdchanged-hook.bats
# Integration tests for CAST_STACK_PROFILE injection in cast-cwdchanged-hook.sh
# All tests use isolated temp dirs — never touch real $HOME or the repo.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$REPO_DIR/scripts/cast-cwdchanged-hook.sh"
DETECT_SCRIPT="$REPO_DIR/scripts/cast-stack-detect.sh"

setup() {
  # Isolated HOME with detect script seeded
  FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
  mkdir -p "$FAKE_HOME/.claude/scripts"
  cp "$DETECT_SCRIPT" "$FAKE_HOME/.claude/scripts/cast-stack-detect.sh"

  # Fake repo root
  FAKE_REPO="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_REPO"

  export HOME="$FAKE_HOME"
  unset CLAUDE_SUBPROCESS
}

teardown() {
  unset HOME CLAUDE_SUBPROCESS
}

# ── Test 1: vite repo → CAST_STACK_PROFILE in environment ────────────────
@test "CwdChanged in vite repo emits CAST_STACK_PROFILE in environment" {
  # Seed fake repo as a vite project
  printf '%s\n' '{"scripts":{"build":"vite build","lint":"eslint ."},"dependencies":{"vite":"^5.0.0","react":"^18.0.0"}}' \
    > "$FAKE_REPO/package.json"
  mkdir -p "$FAKE_REPO/.claude"

  HOOK_INPUT="{\"new_cwd\":\"$FAKE_REPO\",\"previous_cwd\":\"/tmp\"}"
  run bash "$HOOK_SCRIPT" <<< "$HOOK_INPUT"
  [ "$status" -eq 0 ]

  # Output must be valid JSON containing CAST_STACK_PROFILE
  HOOK_OUT="$output" python3 << 'PY'
import json, os
out = json.loads(os.environ['HOOK_OUT'])
env = out['hookSpecificOutput']['environment']
assert 'CAST_STACK_PROFILE' in env, f"CAST_STACK_PROFILE missing from environment: {env}"
profile = json.loads(env['CAST_STACK_PROFILE'])
assert profile.get('fw') == 'vite-react', f"Expected vite-react, got: {profile.get('fw')}"
PY
}

# ── Test 2: no cast.json → graceful fallback (no CAST_STACK_PROFILE or empty) ──
@test "CwdChanged with no package.json yields graceful fallback without error" {
  # FAKE_REPO is empty — unknown stack
  HOOK_INPUT="{\"new_cwd\":\"$FAKE_REPO\",\"previous_cwd\":\"/tmp\"}"
  run bash "$HOOK_SCRIPT" <<< "$HOOK_INPUT"
  [ "$status" -eq 0 ]

  # Output must be valid JSON and hook must not crash
  HOOK_OUT="$output" python3 << 'PY'
import json, os
out = json.loads(os.environ['HOOK_OUT'])
env = out['hookSpecificOutput']['environment']
# CAST_REPO_CLASS must always be present
assert 'CAST_REPO_CLASS' in env, f"CAST_REPO_CLASS missing: {env}"
# CAST_STACK_PROFILE may be absent or empty (unknown repo → compact fw=unknown, empty cmds)
profile_str = env.get('CAST_STACK_PROFILE', '')
if profile_str:
    profile = json.loads(profile_str)
    assert profile.get('fw') == 'unknown', f"Expected unknown fw, got: {profile.get('fw')}"
PY
}
