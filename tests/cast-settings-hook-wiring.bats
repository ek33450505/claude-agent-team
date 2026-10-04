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
FRAGMENTS_DIR="${BATS_TEST_DIRNAME}/../managed-settings.d"

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

# ---------------------------------------------------------------------------
# Hook `if` field regression (2026-10-04, unit P1-a).
# Claude Code: the `if` field holds exactly ONE permission rule — there is no
# `||`, `&&`, or list syntax. A value like "Write|Edit|Bash" is read as a rule
# for a tool literally named "Write|Edit|Bash", matches nothing, and the hook
# silently never spawns (post-tool-hook.sh was dead from 2026-07-05 this way).
# Tool alternation belongs in the entry `matcher` (a regex), not in `if`.
#
# Second instance of the class (2026-10-04): managed-settings.d/27-hooks-advanced.json
# carried `Write(**/.env*|**/auth/**|...)` path rules. File-path rules use
# gitignore syntax, which has no `|` alternation, so each was one literal
# pattern that matched no path and the guards never fired. The fragment was
# removed; this test now guards future additions (zero `if` fields is valid).
# ---------------------------------------------------------------------------

@test "every hook if-field in managed-settings.d holds a single permission rule (no | lists)" {
  run env FRAGMENTS_DIR="$FRAGMENTS_DIR" python3 -c "
import glob, json, os, re
frag_dir = os.environ['FRAGMENTS_DIR']
bad = []
file_tools = ('Read', 'Edit', 'Write', 'NotebookEdit', 'Glob')
for path in sorted(glob.glob(os.path.join(frag_dir, '*.json'))):
  with open(path) as f:
    d = json.load(f)
  for event, entries in (d.get('hooks') or {}).items():
    for entry in entries:
      for h in entry.get('hooks', []):
        if 'if' not in h:
          continue
        val = h['if']
        tool = val.split('(', 1)[0] if isinstance(val, str) else ''
        where = os.path.basename(path) + ':' + event + ':' + repr(val)
        if not re.match(r'^[A-Za-z0-9_*]+\$', tool):
          bad.append(where)
        elif tool in file_tools and '(' in val and '|' in val.split('(', 1)[1]:
          # file-path rules are gitignore syntax: no | alternation (Bash(...) may hold a real pipe)
          bad.append(where)
assert not bad, 'if-field is not a single permission rule: ' + '; '.join(bad)
print('OK')
"
  assert_output "OK"
}

@test "post-tool-hook.sh PostToolUse handler is not narrowed by an if-filter" {
  run python3 -c "
import json
with open('$SETTINGS') as f:
  s = json.load(f)
found = []
for entry in s['hooks'].get('PostToolUse', []):
  for h in entry.get('hooks', []):
    if 'post-tool-hook.sh' in h.get('command', ''):
      found.append((entry, h))
assert len(found) == 1, f'Expected exactly one post-tool-hook.sh PostToolUse handler, got {len(found)}'
entry, h = found[0]
assert 'if' not in h, f'post-tool-hook.sh handler carries an if-filter (silently never spawns on a | list): {h[\"if\"]!r}'
matcher = entry.get('matcher', '')
for tool in ('Write', 'Edit', 'Bash', 'Agent'):
  assert tool in matcher, f'matcher {matcher!r} does not cover {tool}'
print('OK')
"
  assert_output "OK"
}
