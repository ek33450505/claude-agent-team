#!/usr/bin/env bats
# cast-sandbox-u6-config.bats -- static + merge checks for the U6b/U6c security config:
#   61-sandbox.json sandbox.filesystem.denyWrite (.git/worktrees, .githooks)
#   12-ask.json permissions.ask (Edit/Write on .githooks)
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

@test "12-ask.json ask contains Edit and Write rules for .githooks" {
  run jq_py "$ASK" "'Edit(**/.githooks/**)' in d['permissions']['ask'] and 'Write(**/.githooks/**)' in d['permissions']['ask']"
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

@test "real merge keeps both denyWrite entries, the .githooks ask rules, AND existing ask entries" {
  mkdir -p "$HOME/.claude/managed-settings.d"
  cp "$REPO_DIR"/managed-settings.d/*.json "$HOME/.claude/managed-settings.d/"
  out="$HOME/.claude/settings.json"
  run bash "$MERGE_SH" "$out"
  assert_success
  run jq_py "$out" "{'~/Projects/**/.git/worktrees', '~/Projects/**/.githooks'} <= set(d['sandbox']['filesystem']['denyWrite'])"
  assert_success
  run jq_py "$out" "{'Edit(**/.githooks/**)', 'Write(**/.githooks/**)', 'mcp__neon__delete_branch'} <= set(d['permissions']['ask'])"
  assert_success
  # a different array key in the same dict must survive (allowWrite/denyRead siblings)
  run jq_py "$out" "'/tmp' in d['sandbox']['filesystem']['allowWrite'] and d['sandbox']['filesystem']['denyRead']"
  assert_success
}

@test "repo-root settings.json (hand-maintained merged copy) carries all four U6 entries" {
  run jq_py "$REPO_DIR/settings.json" "{'~/Projects/**/.git/worktrees', '~/Projects/**/.githooks'} <= set(d['sandbox']['filesystem']['denyWrite']) and {'Edit(**/.githooks/**)', 'Write(**/.githooks/**)'} <= set(d['permissions']['ask'])"
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
