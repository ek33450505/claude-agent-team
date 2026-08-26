#!/usr/bin/env bats
# CAST v10 SEC-3 regression: no tracked CAST script may pass --bare to
# `claude` on the agent-dispatch path.
#
# --bare skips ~/.claude hook auto-discovery (CAST's entire PreToolUse guard
# pipeline — git guard, destructive-op guard, egress sentinel, record-feeding
# hooks) AND never reads OAuth credentials / the system keychain, so a bare
# dispatch fails auth outright. See:
# https://code.claude.com/docs/en/headless ("Start faster with bare mode").
#
# Structural enforcement (not prompt wording): scans every *tracked*
# scripts/*.sh and plugin/scripts/*.sh file via `git ls-files` (never a
# working-tree glob — untracked files, e.g. generator scratch output, must
# not be scanned or this would false-positive/false-negative unpredictably).
#
# Scope is deliberately narrowed to scripts/ and plugin/scripts/ so this
# test file's own literal '--bare' mentions (in this comment block and the
# grep pattern below) can never self-match.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "no tracked scripts/*.sh or plugin/scripts/*.sh passes --bare to claude" {
  cd "$REPO_ROOT"

  local hits=""
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -n -- '--bare' "$f" >/dev/null 2>&1; then
      local matches
      matches="$(grep -n -- '--bare' "$f" | while IFS= read -r line; do printf '%s:%s\n' "$f" "$line"; done)"
      hits="${hits}${matches}
"
    fi
  done < <(git ls-files 'scripts/*.sh' 'plugin/scripts/*.sh')

  if [ -n "$hits" ]; then
    {
      echo "FORBIDDEN: '--bare' found in a tracked CAST script's claude dispatch."
      echo "--bare skips ~/.claude hook auto-discovery (the entire PreToolUse"
      echo "guard pipeline) and never reads OAuth credentials/the keychain"
      echo "(https://code.claude.com/docs/en/headless). Offending file:line(s):"
      echo "$hits"
    } >&2
    return 1
  fi
}
