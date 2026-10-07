#!/usr/bin/env bats
# cast-sandbox-u6-config.bats -- static + merge checks for the U6b/U6c security config:
#   61-sandbox.json sandbox.filesystem.denyWrite (.git/worktrees, .githooks)
#   12-ask.json permissions.ask (Edit on .githooks; NO Write rule -- Write path rules are inert,
#     only Edit(path) is consulted for file tools; the mode-independent gate is the
#     githooks-require-security policy, see tests/cast-githooks-policy.bats)
# These do NOT prove live enforcement (settings apply only after install + a new
# session); see docs/architecture/enforcement-awareness-split.md for the live-probe list.
# Isolated temp HOME; no real settings touched.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SANDBOX="$REPO_DIR/managed-settings.d/61-sandbox.json"
ASK="$REPO_DIR/managed-settings.d/12-ask.json"
MERGE_SH="$REPO_DIR/scripts/cast-merge-settings.sh"

setup() { setup_temp_home; }
teardown() { teardown_temp_home; }

jq_py() {
  # jq_py <file> <python-expr over d>
  python3 -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert $2
" "$1"
}

@test "61-sandbox.json denyWrite contains ~/Projects/**/.git/worktrees" {
  run jq_py "$SANDBOX" "'~/Projects/**/.git/worktrees' in d['sandbox']['filesystem']['denyWrite']"
  assert_success
}

@test "61-sandbox.json denyWrite contains ~/Projects/**/.githooks" {
  run jq_py "$SANDBOX" "'~/Projects/**/.githooks' in d['sandbox']['filesystem']['denyWrite']"
  assert_success
}

@test "61-sandbox.json sandbox filesystem paths never use a ./ prefix (user-layer = ~/.claude)" {
  run python3 -I -c "
import json, sys
fs = json.load(open(sys.argv[1]))['sandbox']['filesystem']
bad = [p for k, v in fs.items() if isinstance(v, list) for p in v if isinstance(p, str) and p.startswith(('./', '../'))]
assert not bad, bad
" "$SANDBOX"
  assert_success
}

@test "12-ask.json ask contains the Edit rule for .githooks and NO inert Write rule" {
  # Write(path) rules are inert per the Claude Code permissions docs (only Edit(path) is
  # consulted for file tools), so a Write ask rule is false reassurance and must stay absent.
  run jq_py "$ASK" "'Edit(**/.githooks/**)' in d['permissions']['ask'] and 'Write(**/.githooks/**)' not in d['permissions']['ask']"
  assert_success
}

@test "12-ask.json no ask rule uses | alternation (silently matches nothing)" {
  run python3 -I -c "
import json, sys
bad = [r for r in json.load(open(sys.argv[1]))['permissions']['ask'] if '|' in r]
assert not bad, bad
" "$ASK"
  assert_success
}

@test "real merge keeps both denyWrite entries, the .githooks Edit ask rule (no Write rule), AND existing ask entries" {
  mkdir -p "$HOME/.claude/managed-settings.d"
  cp "$REPO_DIR"/managed-settings.d/*.json "$HOME/.claude/managed-settings.d/"
  out="$HOME/.claude/settings.json"
  run bash "$MERGE_SH" "$out"
  assert_success
  run jq_py "$out" "{'~/Projects/**/.git/worktrees', '~/Projects/**/.githooks'} <= set(d['sandbox']['filesystem']['denyWrite'])"
  assert_success
  run jq_py "$out" "{'Edit(**/.githooks/**)', 'mcp__neon__delete_branch'} <= set(d['permissions']['ask']) and 'Write(**/.githooks/**)' not in d['permissions']['ask']"
  assert_success
  # a different array key in the same dict must survive (allowWrite/denyRead siblings)
  run jq_py "$out" "'/tmp' in d['sandbox']['filesystem']['allowWrite'] and d['sandbox']['filesystem']['denyRead']"
  assert_success
}

@test "repo-root settings.json (hand-maintained merged copy) carries the U6 entries (Edit ask, no Write ask)" {
  run jq_py "$REPO_DIR/settings.json" "{'~/Projects/**/.git/worktrees', '~/Projects/**/.githooks'} <= set(d['sandbox']['filesystem']['denyWrite']) and 'Edit(**/.githooks/**)' in d['permissions']['ask'] and 'Write(**/.githooks/**)' not in d['permissions']['ask']"
  assert_success
}

@test "61-sandbox.json denyWrite entries are ~/Projects-scoped (no /** or /tmp prefix: would break sandboxed temp fixtures)" {
  run python3 -I -c "
import json, sys
dw = json.load(open(sys.argv[1]))['sandbox']['filesystem']['denyWrite']
assert dw, 'denyWrite empty'
bad = [p for p in dw if p.startswith(('/**', '/tmp', '/private/tmp', '**'))]
assert not bad, bad
" "$SANDBOX"
  assert_success
}

# U6c-3 (Ed, 2026-10-07): docker/bq/osascript were dropped from sandbox.excludedCommands. They were
# inert exact matches (a bare `docker`, not `docker *`) and a sandbox escape if ever widened, so
# nothing may be excluded from the sandbox. Guards BOTH the fragment and the committed merged copy.
@test "61-sandbox.json excludes no commands from the sandbox (docker/bq/osascript dropped)" {
  run jq_py "$SANDBOX" "not d['sandbox'].get('excludedCommands')"
  assert_success
}

@test "repo-root settings.json excludes no commands from the sandbox" {
  run jq_py "$REPO_DIR/settings.json" "not d['sandbox'].get('excludedCommands')"
  assert_success
}

@test "merged fragments exclude no commands from the sandbox (real merge into a temp HOME)" {
  mkdir -p "$HOME/.claude/managed-settings.d"
  cp "$REPO_DIR"/managed-settings.d/*.json "$HOME/.claude/managed-settings.d/"
  run bash "$MERGE_SH" "$HOME/merged.json"
  assert_success
  run jq_py "$HOME/merged.json" "'sandbox' in d and not d['sandbox'].get('excludedCommands')"
  assert_success
}

# U6d: the integrity manifest, its pyc snapshot and the interpreter/launchd cache roots are read by
# the SessionStart integrity check. The Bash write guard covers shell writes; these Edit denies close
# the Write/Edit-tool route (only Edit(path) rules are consulted for file tools).
@test "11-deny.json and repo settings.json both deny Edit on the integrity-check roots" {
  local f
  for f in "$REPO_DIR/managed-settings.d/11-deny.json" "$REPO_DIR/settings.json"; do
    run jq_py "$f" "{'Edit(~/.claude/cast-state/**)', 'Edit(~/Library/Caches/com.apple.python/**)', 'Edit(~/Library/Python/**)', 'Edit(~/Library/LaunchAgents/**)', 'Edit(~/.claude/install-manifest.sha256)'} <= set(d['permissions']['deny'])"
    assert_success
  done
}
