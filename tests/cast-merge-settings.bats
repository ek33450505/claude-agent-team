#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MERGE_SH="$REPO_DIR/scripts/cast-merge-settings.sh"

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  export ORIG_HOME="$HOME"
  export HOME="$(realpath "$(mktemp -d)")"
  mkdir -p "$HOME/.claude/managed-settings.d"
  export FRAGMENTS_DIR="$HOME/.claude/managed-settings.d"
  export OUTPUT_FILE="$HOME/merged-output.json"
}

teardown() {
  rm -rf "$HOME"
  export HOME="$ORIG_HOME"
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
