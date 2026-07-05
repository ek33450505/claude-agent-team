#!/usr/bin/env bats
# tests/cast-settings-hook-wiring.bats
# Asserts that settings.json correctly wires all required hook entries.
#
# REAL INVARIANT (v9, 2026-07-04):
#   The committed settings.json is a BUILD ARTIFACT produced by:
#     bash scripts/cast-merge-settings.sh <output_path>
#   which deep-merges all managed-settings.d/*.json fragments in lexicographic
#   order. The CI gate .github/workflows/settings-drift.yml enforces that the
#   committed file matches the merged fragment output on every push/PR.
#
# v9 WIRING INVARIANT:
#   PreToolUse must contain cast-pretool-dispatch.py (the v9 consolidated
#   dispatcher, id=cast-pretool-dispatch, wired in managed-settings.d/
#   25-hooks-security.json). The legacy pre-tool-guard.sh and
#   cast-command-guard.sh hook commands must NOT appear — they were replaced
#   by cast-pretool-dispatch.py and are not present in any fragment.
#
# Semantic checks (find by id / command substring) are used rather than
# strict positional assumptions. Additional Stop/Start entries may be present
# from non-journal fragments — tests tolerate that.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

SETTINGS="${BATS_TEST_DIRNAME}/../settings.json"

@test "settings.json has at least 3 SessionStart entries" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
starts = s['hooks'].get('SessionStart', [])
assert len(starts) >= 3, f'Expected at least 3 SessionStart entries, got {len(starts)}'
print('OK')
"
  assert_output "OK"
}

@test "SessionStart contains cast-time-context and cast-session-start-journal entries" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
starts = s['hooks'].get('SessionStart', [])
ids = [h.get('id', '') for h in starts]
assert 'cast-time-context' in ids, f'cast-time-context missing from SessionStart ids: {ids}'
assert 'cast-session-start-journal' in ids, f'cast-session-start-journal missing from SessionStart ids: {ids}'
print('OK')
"
  assert_output "OK"
}

@test "Stop contains an entry with id cast-journal-session-end" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
stops = s['hooks'].get('Stop', [])
ids = [h.get('id', '') for h in stops]
assert 'cast-journal-session-end' in ids, f'cast-journal-session-end missing from Stop ids: {ids}'
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
journal_entry = next((h for h in starts if h.get('id') == 'cast-session-start-journal'), None)
assert journal_entry is not None, 'cast-session-start-journal entry missing'
cmd = journal_entry['hooks'][0]['command']
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
journal_stop = next((h for h in stops if h.get('id') == 'cast-journal-session-end'), None)
assert journal_stop is not None, 'cast-journal-session-end entry missing from Stop'
cmd = journal_stop['hooks'][0]['command']
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
journal_stop = next((h for h in stops if h.get('id') == 'cast-journal-session-end'), None)
assert journal_stop is not None, 'cast-journal-session-end entry missing'
timeout = journal_stop['hooks'][0].get('timeout')
assert timeout == 5, f'Expected timeout 5, got {timeout}'
print('OK')
"
  assert_output "OK"
}

@test "broken git agent-hook is NOT present in PreToolUse hooks" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
pretool_hooks = s['hooks'].get('PreToolUse', [])
# Verify no agent-type hook exists in PreToolUse
for entry in pretool_hooks:
  hooks = entry.get('hooks', [])
  for hook in hooks:
    assert hook.get('type') != 'agent', f'Found agent-type hook in PreToolUse (broken git-push hook): {hook}'
print('OK')
"
  assert_output "OK"
}

@test "deterministic git push block remains in cast-git-guard.py" {
  # CAST v9 P0: the git/push logic moved from pre-tool-guard.sh into the importable
  # cast-git-guard.py (now shared by the wrapper + cast-pretool-dispatch.py). The
  # guarantee is unchanged — re-proven in its new home.
  local guard="${BATS_TEST_DIRNAME}/../scripts/cast-git-guard.py"
  grep -q 'git push block' "$guard"
  grep -q 'CAST_PUSH_OK' "$guard"
}

# ---------------------------------------------------------------------------
# v9 wiring assertions — cast-pretool-dispatch.py replaces the legacy guards
# (managed-settings.d/25-hooks-security.json, id=cast-pretool-dispatch).
# The assertions below FAIL against the stale committed settings.json and
# PASS once settings.json is regenerated from fragments via the CI gate
# (.github/workflows/settings-drift.yml).
# ---------------------------------------------------------------------------

@test "PreToolUse contains cast-pretool-dispatch.py (v9 consolidated dispatcher)" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
pretool = s['hooks'].get('PreToolUse', [])
cmds = [hook.get('command', '') for entry in pretool for hook in entry.get('hooks', [])]
found = any('cast-pretool-dispatch.py' in c for c in cmds)
assert found, f'cast-pretool-dispatch.py not found in PreToolUse commands: {cmds}'
print('OK')
"
  assert_output "OK"
}

@test "PreToolUse does NOT contain legacy pre-tool-guard.sh" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
pretool = s['hooks'].get('PreToolUse', [])
cmds = [hook.get('command', '') for entry in pretool for hook in entry.get('hooks', [])]
bad = [c for c in cmds if 'pre-tool-guard.sh' in c]
assert not bad, f'Legacy pre-tool-guard.sh still wired in PreToolUse (should be absent): {bad}'
print('OK')
"
  assert_output "OK"
}

@test "PreToolUse does NOT contain legacy cast-command-guard.sh" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
pretool = s['hooks'].get('PreToolUse', [])
cmds = [hook.get('command', '') for entry in pretool for hook in entry.get('hooks', [])]
bad = [c for c in cmds if 'cast-command-guard.sh' in c]
assert not bad, f'Legacy cast-command-guard.sh still wired in PreToolUse (should be absent): {bad}'
print('OK')
"
  assert_output "OK"
}
