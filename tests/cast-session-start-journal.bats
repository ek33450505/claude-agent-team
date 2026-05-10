#!/usr/bin/env bats
# tests/cast-session-start-journal.bats
# Tests for cast-session-start-journal.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/cast-session-start-journal.sh"

setup() {
  mkdir -p "${HOME}/.claude/logs"
}

@test "hook exits 0 in subprocess mode" {
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"
  assert_success
  assert_output ""
}

@test "output is valid JSON when entries exist" {
  skip "Requires actual journal entries in ~/Documents/Claude/"
}

@test "output contains systemMessage on vault directory missing" {
  # Temporarily move vault if it exists
  VAULT_BACKUP=""
  if [[ -d ~/Documents/Claude ]]; then
    VAULT_BACKUP=$(mktemp -d)
    mv ~/Documents/Claude "$VAULT_BACKUP/Claude" || true
  fi

  run bash "$SCRIPT"

  # Restore vault
  if [[ -d "$VAULT_BACKUP/Claude" ]]; then
    mv "$VAULT_BACKUP/Claude" ~/Documents/Claude || true
    rmdir "$VAULT_BACKUP" || true
  fi

  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'systemMessage' in d, 'systemMessage missing'
msg = d.get('systemMessage', '')
assert 'Vault directory' in msg and 'not found' in msg, f'Unexpected message: {msg}'
"
}

@test "systemMessage indicates missing vault with warning emoji" {
  VAULT_BACKUP=""
  if [[ -d ~/Documents/Claude ]]; then
    VAULT_BACKUP=$(mktemp -d)
    mv ~/Documents/Claude "$VAULT_BACKUP/Claude" || true
  fi

  run bash "$SCRIPT"

  if [[ -d "$VAULT_BACKUP/Claude" ]]; then
    mv "$VAULT_BACKUP/Claude" ~/Documents/Claude || true
    rmdir "$VAULT_BACKUP" || true
  fi

  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
msg = d.get('systemMessage', '')
assert msg.startswith('📓 journal |'), f'Missing journal emoji/prefix: {repr(msg[:30])}'
assert '⚠️' in msg, f'Missing warning emoji in: {msg}'
"
}

@test "hookSpecificOutput.hookEventName is SessionStart" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
hook_output = d.get('hookSpecificOutput', {})
assert hook_output.get('hookEventName') == 'SessionStart', \
  f\"expected SessionStart, got: {hook_output.get('hookEventName')}\"
"
}

@test "additionalContext is string even when no entries found" {
  VAULT_BACKUP=""
  if [[ -d ~/Documents/Claude ]]; then
    VAULT_BACKUP=$(mktemp -d)
    mv ~/Documents/Claude "$VAULT_BACKUP/Claude" || true
  fi

  run bash "$SCRIPT"

  if [[ -d "$VAULT_BACKUP/Claude" ]]; then
    mv "$VAULT_BACKUP/Claude" ~/Documents/Claude || true
    rmdir "$VAULT_BACKUP" || true
  fi

  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d['hookSpecificOutput'].get('additionalContext')
assert isinstance(ctx, str), f'additionalContext must be string, got {type(ctx)}'
"
}

@test "both systemMessage and hookSpecificOutput present in output" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'systemMessage' in d, 'systemMessage missing from output'
assert 'hookSpecificOutput' in d, 'hookSpecificOutput missing from output'
# systemMessage is always a string
assert isinstance(d.get('systemMessage'), str), 'systemMessage must be string'
# hookSpecificOutput is always an object
assert isinstance(d.get('hookSpecificOutput'), dict), 'hookSpecificOutput must be object'
"
}
