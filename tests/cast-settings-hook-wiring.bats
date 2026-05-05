#!/usr/bin/env bats
# tests/cast-settings-hook-wiring.bats
# Asserts that settings.json correctly wires all required hook entries.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

@test "settings.json has exactly 3 SessionStart entries" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
starts = s['hooks'].get('SessionStart', [])
assert len(starts) == 3, f'Expected 3 SessionStart entries, got {len(starts)}'
print('OK')
"
  assert_output "OK"
}

@test "SessionStart entries are in correct order: cast-session-start, cast-time-context, cast-session-start-journal" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
starts = s['hooks'].get('SessionStart', [])
ids = [h['id'] for h in starts]
expected = ['cast-session-start', 'cast-time-context', 'cast-session-start-journal']
assert ids == expected, f'Wrong order: {ids}'
print('OK')
"
  assert_output "OK"
}

@test "settings.json has exactly 1 Stop entry with id cast-journal-session-end" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
stops = s['hooks'].get('Stop', [])
assert len(stops) == 1, f'Expected 1 Stop entry, got {len(stops)}'
assert stops[0]['id'] == 'cast-journal-session-end', f\"Wrong Stop id: {stops[0]['id']}\"
print('OK')
"
  assert_output "OK"
}

@test "cast-session-start-journal hook points to an existing script" {
  run python3 -c "
import json, os
with open('$SETTINGS') as f:
  s = json.load(f)
starts = s['hooks'].get('SessionStart', [])
journal_entry = next((h for h in starts if h['id'] == 'cast-session-start-journal'), None)
assert journal_entry is not None, 'cast-session-start-journal entry missing'
cmd = journal_entry['hooks'][0]['command']
# Extract script path (after 'bash ')
script_path = os.path.expanduser(cmd.replace('bash ', '', 1).strip())
assert os.path.isfile(script_path), f'Script not found: {script_path}'
print('OK')
"
  assert_output "OK"
}

@test "cast-journal-session-end hook points to an existing script" {
  run python3 -c "
import json, os
with open('$SETTINGS') as f:
  s = json.load(f)
stops = s['hooks'].get('Stop', [])
assert len(stops) == 1, 'No Stop entries'
cmd = stops[0]['hooks'][0]['command']
script_path = os.path.expanduser(cmd.replace('bash ', '', 1).strip())
assert os.path.isfile(script_path), f'Script not found: {script_path}'
print('OK')
"
  assert_output "OK"
}

@test "cast-journal-session-end has timeout 5" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
stops = s['hooks'].get('Stop', [])
timeout = stops[0]['hooks'][0].get('timeout')
assert timeout == 5, f'Expected timeout 5, got {timeout}'
print('OK')
"
  assert_output "OK"
}
