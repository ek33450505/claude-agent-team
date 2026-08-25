#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MERGE_SH="$REPO_DIR/scripts/cast-merge-settings.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home
  mkdir -p "$HOME/.claude/managed-settings.d"
  export FRAGMENTS_DIR="$HOME/.claude/managed-settings.d"
  export OUTPUT_FILE="$HOME/merged-output.json"
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Helper: write a fragment file
# ---------------------------------------------------------------------------

write_fragment() {
  local name="$1"
  local content="$2"
  echo "$content" > "$FRAGMENTS_DIR/$name"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "basic merge: two simple fragments produce a valid combined JSON object" {
  write_fragment "00-a.json" '{"env": {"FOO": "bar"}}'
  write_fragment "10-b.json" '{"model": "sonnet"}'

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success
  assert_output --partial "merged 2 fragments"

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
assert d['env']['FOO'] == 'bar', 'env.FOO missing'
assert d['model'] == 'sonnet', 'model missing'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "hooks merge: two fragments with hooks key get their events deep-merged (not clobbered)" {
  write_fragment "00-hooks-a.json" '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo start"}]}]}}'
  write_fragment "10-hooks-b.json" '{"hooks": {"SessionEnd": [{"hooks": [{"type": "command", "command": "echo end"}]}]}}'

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
assert 'SessionStart' in hooks, 'SessionStart missing from merged hooks'
assert 'SessionEnd' in hooks, 'SessionEnd missing from merged hooks'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "hooks merge: same hook event arrays from two fragments are concatenated, not replaced" {
  write_fragment "00-pre.json" '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "echo first"}]}]}}'
  write_fragment "10-pre2.json" '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "echo second"}]}]}}'

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
entries = d.get('hooks', {}).get('PreToolUse', [])
assert len(entries) == 2, f'Expected 2 PreToolUse entries, got {len(entries)}'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "sort order: fragments are applied in lexicographic order (00- before 10- before 20-)" {
  write_fragment "20-last.json" '{"model": "third"}'
  write_fragment "00-first.json" '{"model": "first"}'
  write_fragment "10-second.json" '{"model": "second"}'

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
# Later fragment (20-) should win
assert d['model'] == 'third', f'Expected \"third\" (last fragment wins), got {d[\"model\"]}'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "invalid JSON fragment: script exits non-zero and does NOT write to output" {
  write_fragment "00-valid.json" '{"env": {"A": "1"}}'
  write_fragment "10-bad.json" '{this is not valid json}'
  # Pre-create output so we can verify it was NOT modified
  echo '{"original": true}' > "$OUTPUT_FILE"

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_failure

  # Output file should be unchanged
  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
assert d.get('original') == True, 'Output was modified despite invalid fragment'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "missing managed-settings.d/ directory: script exits non-zero with error message" {
  rmdir "$FRAGMENTS_DIR"

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_failure
  assert_output --partial "fragment dir not found"
}

@test "empty fragment directory: script exits non-zero" {
  # Fragments dir exists but has no .json files
  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_failure
  assert_output --partial "no *.json fragments found"
}

@test "output is valid JSON: verified with python3 -m json.tool" {
  write_fragment "00-env.json" '{"env": {"X": "1"}}'
  write_fragment "10-hooks.json" '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]}}'

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -m json.tool "$OUTPUT_FILE"
  assert_success
}

@test "output path argument is respected: writes to custom path not default" {
  write_fragment "00-env.json" '{"env": {"Y": "2"}}'
  CUSTOM_OUT="$HOME/custom-settings.json"

  run bash "$MERGE_SH" "$CUSTOM_OUT"
  assert_success
  assert_output --partial "$CUSTOM_OUT"

  [ -f "$CUSTOM_OUT" ]
}

@test "permissions deny+allow merge: 10-permissions.json (allow) + 11-deny.json (deny) produce a permissions object with BOTH allow and deny arrays" {
  printf '%s\n' '{"permissions":{"allow":["Bash","Write","Edit"]}}' \
    > "$FRAGMENTS_DIR/10-permissions.json"
  printf '%s\n' '{"permissions":{"deny":["Agent(model:claude-fable*)","Agent(model:claude-mythos*)","Agent(model:fable*)","Agent(model:mythos*)","Bash(pkill *)","Bash(killall *)","Bash(rm -rf ~)","Bash(rm -rf ~/)","Bash(rm -rf ~/.claude*)"]}}' \
    > "$FRAGMENTS_DIR/11-deny.json"

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
perms = d.get('permissions', {})
allow = perms.get('allow', [])
deny = perms.get('deny', [])
assert 'Bash' in allow, f'allow missing Bash: {allow}'
assert 'Write' in allow, f'allow missing Write: {allow}'
assert 'Edit' in allow, f'allow missing Edit: {allow}'
# 9 entries after FIX A+B (v9 security review)
assert len(deny) == 9, f'Expected 9 deny entries, got {len(deny)}: {deny}'
# Model cap entries — claude-fable* (broad) supersedes the former claude-fable-5*
assert 'Agent(model:claude-fable*)' in deny, 'claude-fable* model deny missing'
assert 'Agent(model:claude-mythos*)' in deny, 'mythos model deny missing'
assert 'Agent(model:fable*)' in deny, 'fable bare alias deny missing'
assert 'Agent(model:mythos*)' in deny, 'mythos bare alias deny missing'
# Process kill
assert 'Bash(pkill *)' in deny, 'pkill deny missing'
assert 'Bash(killall *)' in deny, 'killall deny missing'
# Destructive rm — exact home-root entries (FIX A: narrowed from over-broad ~*)
assert 'Bash(rm -rf ~)' in deny, 'rm -rf ~ exact deny missing'
assert 'Bash(rm -rf ~/)' in deny, 'rm -rf ~/ exact deny missing'
assert 'Bash(rm -rf ~/.claude*)' in deny, 'rm -rf ~/.claude deny missing'
# Regression guard: the over-broad ~* pattern must NOT be present
assert 'Bash(rm -rf ~*)' not in deny, 'over-broad rm -rf ~* must not be present'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "permissions deny merge: allow array is unchanged when deny fragment is merged on top" {
  printf '%s\n' '{"permissions":{"allow":["Bash","Write","Edit","WebSearch"]}}' \
    > "$FRAGMENTS_DIR/10-permissions.json"
  printf '%s\n' '{"permissions":{"deny":["Bash(pkill *)"]}}' \
    > "$FRAGMENTS_DIR/11-deny.json"

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
allow = d.get('permissions', {}).get('allow', [])
assert allow == ['Bash', 'Write', 'Edit', 'WebSearch'], f'allow clobbered: {allow}'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "11-deny.json is valid JSON" {
  DENY_FRAG="$REPO_DIR/managed-settings.d/11-deny.json"
  [ -f "$DENY_FRAG" ]
  run python3 -m json.tool "$DENY_FRAG"
  assert_success
}

@test "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH fragment: 00-env.json sets it to \"1\"" {
  ENV_FRAG="$REPO_DIR/managed-settings.d/00-env.json"
  [ -f "$ENV_FRAG" ]
  run python3 -c "
import json
with open('$ENV_FRAG') as f:
    d = json.load(f)
val = d.get('env', {}).get('CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')
assert val == '1', f'expected \"1\", got {val!r}'
print('ok')
"
  assert_success
  assert_output "ok"
}

@test "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH survives the fragment-to-merged hop" {
  # Reproduce the settings-drift.yml recipe with the REAL repo fragments
  # (not synthetic ones) so this catches a key that never reaches the
  # merged artifact — a recorded CAST failure mode ("delivered but never read").
  cp "$REPO_DIR"/managed-settings.d/*.json "$FRAGMENTS_DIR/"

  run bash "$MERGE_SH" "$OUTPUT_FILE"
  assert_success

  run python3 -c "
import json
with open('$OUTPUT_FILE') as f:
    d = json.load(f)
val = d.get('env', {}).get('CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH')
assert val == '1', f'merged env missing/wrong: {val!r}'
print('ok')
"
  assert_success
  assert_output "ok"
}
