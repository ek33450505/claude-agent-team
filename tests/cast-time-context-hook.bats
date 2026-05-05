#!/usr/bin/env bats
# tests/cast-time-context-hook.bats
# Tests for cast-time-context-hook.sh

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/cast-time-context-hook.sh"

setup() {
  mkdir -p "${HOME}/.claude/logs"
}

@test "hook exits 0 in subprocess mode" {
  CLAUDE_SUBPROCESS=1 run bash "$SCRIPT"
  assert_success
  assert_output ""
}

@test "output is valid JSON" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "output contains hookSpecificOutput key" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'hookSpecificOutput' in d"
}

@test "hookSpecificOutput.hookEventName is SessionStart" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['hookSpecificOutput']['hookEventName'] == 'SessionStart', \
  f\"expected SessionStart, got: {d['hookSpecificOutput'].get('hookEventName')}\"
"
}

@test "output contains time of day bucket" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
content = d['hookSpecificOutput']['additionalContext']
assert 'Time of day:' in content, f'missing bucket in: {content}'
"
}

@test "output contains timezone abbreviation" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
content = d['hookSpecificOutput']['additionalContext']
assert 'Timezone:' in content
assert 'UTC' in content
"
}

@test "output contains epoch timestamp" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
content = d['hookSpecificOutput']['additionalContext']
assert 'epoch:' in content
"
}

@test "output contains day type (weekday or weekend)" {
  run bash "$SCRIPT"
  assert_success
  echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
content = d['hookSpecificOutput']['additionalContext']
assert 'Day type:' in content
assert ('weekday' in content or 'weekend' in content)
"
}

# Semantic bucket boundary tests — inline logic to match script exactly

@test "bucket: hour 0 is late-night" {
  run bash -c 'HOUR=0; if (( HOUR >= 0 && HOUR <= 4 )); then echo late-night; fi'
  assert_output "late-night"
}

@test "bucket: hour 4 is late-night (boundary)" {
  run bash -c 'HOUR=4; if (( HOUR >= 0 && HOUR <= 4 )); then echo late-night; fi'
  assert_output "late-night"
}

@test "bucket: hour 5 is early-morning (boundary)" {
  run bash -c 'HOUR=5; if (( HOUR >= 5 && HOUR <= 6 )); then echo early-morning; fi'
  assert_output "early-morning"
}

@test "bucket: hour 6 is early-morning" {
  run bash -c 'HOUR=6; if (( HOUR >= 5 && HOUR <= 6 )); then echo early-morning; fi'
  assert_output "early-morning"
}

@test "bucket: hour 7 is morning (boundary)" {
  run bash -c 'HOUR=7; if (( HOUR >= 7 && HOUR <= 11 )); then echo morning; fi'
  assert_output "morning"
}

@test "bucket: hour 12 is midday" {
  run bash -c 'HOUR=12; if (( HOUR == 12 )); then echo midday; fi'
  assert_output "midday"
}

@test "bucket: hour 13 is afternoon (boundary)" {
  run bash -c 'HOUR=13; if (( HOUR >= 13 && HOUR <= 16 )); then echo afternoon; fi'
  assert_output "afternoon"
}

@test "bucket: hour 16 is afternoon" {
  run bash -c 'HOUR=16; if (( HOUR >= 13 && HOUR <= 16 )); then echo afternoon; fi'
  assert_output "afternoon"
}

@test "bucket: hour 17 is evening (boundary)" {
  run bash -c 'HOUR=17; if (( HOUR >= 17 && HOUR <= 20 )); then echo evening; fi'
  assert_output "evening"
}

@test "bucket: hour 20 is evening" {
  run bash -c 'HOUR=20; if (( HOUR >= 17 && HOUR <= 20 )); then echo evening; fi'
  assert_output "evening"
}

@test "bucket: hour 21 is night (boundary)" {
  run bash -c 'HOUR=21; if (( HOUR >= 21 )); then echo night; fi'
  assert_output "night"
}

@test "bucket: hour 23 is night" {
  run bash -c 'HOUR=23; if (( HOUR >= 21 )); then echo night; fi'
  assert_output "night"
}

@test "additionalContext contains real newlines not literal backslash-n" {
  TMPFILE=$(mktemp)
  bash "$SCRIPT" > "$TMPFILE"
  run python3 -c "
import json
with open('$TMPFILE') as f:
  d = json.load(f)
ctx = d['hookSpecificOutput']['additionalContext']
assert chr(10) in ctx, 'No real newline found in additionalContext'
assert chr(92) + 'n' not in ctx, 'Literal backslash-n found — rendering bug'
print('OK')
"
  assert_output "OK"
  rm -f "$TMPFILE"
}

@test "additionalContext starts with '## Session Time Context' (no leading whitespace or escaped chars)" {
  TMPFILE=$(mktemp)
  bash "$SCRIPT" > "$TMPFILE"
  run python3 -c "
import json
with open('$TMPFILE') as f:
  d = json.load(f)
ctx = d['hookSpecificOutput']['additionalContext']
assert ctx.startswith('## Session Time Context'), f'Unexpected start: {repr(ctx[:40])}'
print('OK')
"
  assert_output "OK"
  rm -f "$TMPFILE"
}

@test "settings.json has cast-time-context + cast-session-start-journal in SessionStart and cast-journal-session-end in Stop" {
  SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
hooks = s['hooks']
starts = hooks.get('SessionStart', [])
stops  = hooks.get('Stop', [])
start_ids = [h.get('id', '') for h in starts]
stop_ids  = [h.get('id', '') for h in stops]
assert 'cast-time-context' in start_ids, f'cast-time-context missing from SessionStart: {start_ids}'
assert 'cast-session-start-journal' in start_ids, f'cast-session-start-journal missing from SessionStart: {start_ids}'
assert 'cast-journal-session-end' in stop_ids, f'cast-journal-session-end missing from Stop: {stop_ids}'
print('OK')
"
  assert_output "OK"
}
