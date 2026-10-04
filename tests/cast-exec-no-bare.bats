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
# NARROW EXCEPTION (commit d03de61): scripts/cast-upgrade-score.sh (and its
# plugin/ copy) classify UNTRUSTED release notes with NO tools and need --bare
# so the notes never reach the CAST hook stack (session distiller -> memory)
# or the user's memory/CLAUDE.md. A tool-less run has no tool calls for the
# PreToolUse guard pipeline to guard. The exception is structural: the file must
# be in ALLOWLIST below AND its non-comment lines must contain both
# `--tools ""` and `--strict-mcp-config`; otherwise it is a violation again.
# The file must also contain exactly one `claude -p`/`--print` call.
# Adding a file to ALLOWLIST REQUIRES A SECURITY REVIEW.
#
# Scope is deliberately narrowed to scripts/ and plugin/scripts/ so this
# test file's own literal '--bare' mentions (in this comment block and the
# grep pattern below) can never self-match.

ALLOWLIST="scripts/cast-upgrade-score.sh plugin/scripts/cast-upgrade-score.sh"

# scan_no_bare ROOT: print violations to stdout; return 1 if any.
scan_no_bare() {
  local root="$1" hits="" f a allowed matches code calls
  while IFS= read -r f; do
    [ -f "$root/$f" ] || continue
    grep -n -- '--bare' "$root/$f" >/dev/null 2>&1 || continue
    allowed=0
    for a in $ALLOWLIST; do [ "$f" = "$a" ] && allowed=1; done
    code="$(grep -v '^[[:space:]]*#' "$root/$f" || true)"
    if [ "$allowed" = 1 ]; then
      # comment-only mentions are fine
      printf '%s\n' "$code" | grep -q -- '--bare' || continue
      # structural co-requirements: tool-less + strict MCP, and EXACTLY ONE
      # claude -p/--print call so the flags cannot belong to a different call
      calls="$(printf '%s\n' "$code" | grep -cE '(^|[^[:alnum:]_-])claude[[:space:]]+(-p|--print)([[:space:]]|$)' || true)"
      if [ "$calls" != 1 ]; then
        hits="${hits}${f}: allowlisted file must have exactly one claude -p/--print call (found $calls)
"
      elif printf '%s\n' "$code" | grep -qF -- '--tools ""' &&
        printf '%s\n' "$code" | grep -qF -- '--strict-mcp-config'; then
        continue
      fi
    fi
    [ "$allowed" = 1 ] && [ "$calls" != 1 ] && continue
    matches="$(grep -n -- '--bare' "$root/$f" | while IFS= read -r line; do printf '%s:%s\n' "$f" "$line"; done)"
    hits="${hits}${matches}
"
  done < <(git -C "$root" ls-files 'scripts/*.sh' 'plugin/scripts/*.sh')
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

# mk_fixture REL BODY: temp git repo with one tracked script.
mk_fixture() {
  local d="$BATS_TEST_TMPDIR/fx"
  rm -rf "${d:?}"
  mkdir -p "$d/$(dirname "$1")"
  printf '%s\n' "$2" >"$d/$1"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" add -A
  echo "$d"
}

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "no tracked scripts/*.sh or plugin/scripts/*.sh passes --bare to claude" {
  run scan_no_bare "$REPO_ROOT"
  if [ "$status" -ne 0 ]; then
    {
      echo "FORBIDDEN: '--bare' found in a tracked CAST script's claude dispatch."
      echo "--bare skips ~/.claude hook auto-discovery (the entire PreToolUse"
      echo "guard pipeline) and never reads OAuth credentials/the keychain"
      echo "(https://code.claude.com/docs/en/headless). Offending file:line(s):"
      echo "$output"
    } >&2
    return 1
  fi
}

@test "fixture: non-allowlisted script with --bare fails" {
  d="$(mk_fixture scripts/other.sh 'claude -p x --bare --tools "" --strict-mcp-config')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/other.sh"* ]]
}

@test "fixture: allowlisted script without --tools \"\" fails" {
  d="$(mk_fixture scripts/cast-upgrade-score.sh 'claude -p x --bare --strict-mcp-config')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
}

@test "fixture: allowlisted script without --strict-mcp-config fails" {
  d="$(mk_fixture plugin/scripts/cast-upgrade-score.sh 'claude -p x --bare --tools ""')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
}

@test "fixture: allowlisted script with both flags passes" {
  d="$(mk_fixture scripts/cast-upgrade-score.sh 'claude -p x --bare --tools "" --strict-mcp-config')"
  run scan_no_bare "$d"
  [ "$status" -eq 0 ]
}

@test "fixture: comment-only --bare in allowlisted script passes; in other script fails" {
  d="$(mk_fixture scripts/cast-upgrade-score.sh '# uses --bare
claude -p x')"
  run scan_no_bare "$d"
  [ "$status" -eq 0 ]
  d="$(mk_fixture scripts/other.sh '# uses --bare')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
}

@test "fixture: allowlisted script with two claude -p calls fails" {
  d="$(mk_fixture scripts/cast-upgrade-score.sh 'claude -p a --bare --tools "" --strict-mcp-config
claude -p b --allowedTools Bash')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one claude -p"* ]]
}

@test "fixture: allowlisted script with --bare but no claude -p call fails" {
  d="$(mk_fixture scripts/cast-upgrade-score.sh 'x="--bare --tools \"\" --strict-mcp-config"')"
  run scan_no_bare "$d"
  [ "$status" -eq 1 ]
}
