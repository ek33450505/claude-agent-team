#!/usr/bin/env bash
# check-plugin-drift.sh — CI gate: generate the plugin to a temp dir and run checks.
#
# Checks:
#   (a) claude plugin validate --strict passes
#   (b) No ~/.claude/scripts paths remain in hooks.json (all rewritten)
#   (c) No SKILL-personal.md under skills/
#   (d) No forbidden plugin frontmatter (hooks|mcpServers|permissionMode) in any agent
#
# Exit code: 0 = all checks pass, 1 = one or more checks failed.

set -euo pipefail

# Hardened git (cast_git_safe): repo-local exec config (core.fsmonitor, ...) must not run from a
# hook. FAIL CLOSED if the lib is not loadable beside this script — never fall back to bare git.
# The -r guard matters: on bash 3.2 a bare `source <missing-file>` aborts under set -e.
_CAST_LIB="$(dirname "$0")/cast-hook-lib.sh"
# shellcheck source=cast-hook-lib.sh
if [[ -r "$_CAST_LIB" ]] && source "$_CAST_LIB"; then
  :
else
  printf 'ERROR: cast-hook-lib.sh not loadable beside %s — refusing to run (fail closed)\n' "$0" >&2
  exit 1
fi
# CAST_REPO_ROOT wins (installed-copy mode: the hook passes the repo as data and this
# script lives in ~/.claude/scripts); else this script's own checkout. GIT_DIR/GIT_WORK_TREE
# are not inherited (a git hook exports the committing worktree's gitdir, S3c-15).
# GIT_INDEX_FILE is kept in the ENVIRONMENT (inherited by the gen-plugin.sh child, which enumerates
# the index with `git ls-files` and opts in via CAST_GIT_SAFE_INDEX_FILE).
if [[ -n "${CAST_REPO_ROOT+x}" ]]; then
  if [[ "$CAST_REPO_ROOT" != /* || ! -d "$CAST_REPO_ROOT" ]]; then
    printf 'ERROR: CAST_REPO_ROOT must be an absolute path to an existing directory: %s\n' "$CAST_REPO_ROOT" >&2
    exit 1
  fi
  REPO_ROOT="$CAST_REPO_ROOT"
else
  REPO_ROOT="$(cast_git_safe "$(dirname "$0")" rev-parse --show-toplevel)"
fi
# The generator is the SIBLING of this script (the installed copy when installed), never
# the repo's own scripts/ — an installed gate must not execute repo-writable code.
GEN_SCRIPT="$(dirname "$0")/gen-plugin.sh"

# Load the cast-guard-lib for safe destructive operations (data-integrity pillar)
# Existence-checked before sourcing — see cast-guard-lib.sh header (bash 3.2 + set -e
# makes `source` of a missing file fatal even left-of-`||`).
_cast_guard_lib="$(dirname "$0")/cast-guard-lib.sh"
[[ -f "$_cast_guard_lib" ]] || _cast_guard_lib="${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}/cast-guard-lib.sh"
if [[ -f "$_cast_guard_lib" ]]; then
  # shellcheck source=cast-guard-lib.sh disable=SC1091
  source "$_cast_guard_lib" 2>/dev/null || true
fi
if ! declare -f cast_safe_rm >/dev/null 2>&1; then
  printf 'ERROR: cast-guard-lib.sh not loaded — cannot safely clean temp dir\n' >&2
  exit 1
fi

PASS=0
FAIL=0

_ok()   { printf '[OK]   %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '[FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Generate to a single temp dir; declare blast radius once and use it for cleanup
TMP="$(mktemp -d)"
cast_declare_blast_radius "$(dirname "$TMP")"
trap 'cast_safe_rm "$TMP" 2>/dev/null || true' EXIT

# Generate the plugin (ignore exit — gen-plugin.sh runs validate internally;
# we re-run validate ourselves below for clean per-check output)
CAST_REPO_ROOT="$REPO_ROOT" bash "$GEN_SCRIPT" "$TMP" 2>/dev/null || true

printf '\n--- Running drift checks ---\n'

# (a) claude plugin validate --strict (skipped if the CLI is unavailable, e.g. CI)
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$TMP" --strict >/dev/null 2>&1; then
    _ok "claude plugin validate --strict: passed"
  else
    VALIDATE_OUT="$(claude plugin validate "$TMP" --strict 2>&1 || true)"
    _fail "claude plugin validate --strict: FAILED"
    printf '%s\n' "$VALIDATE_OUT" >&2
  fi
else
  printf '[SKIP] claude CLI not found — skipping plugin validate (checks b-e still enforced)\n'
fi

# (b) No ~/.claude/scripts paths in hooks.json
HOOKS_JSON="${TMP}/hooks/hooks.json"
if [[ -f "$HOOKS_JSON" ]]; then
  # SC2088 disabled intentionally: we want the LITERAL string ~/.claude/scripts,
  # not tilde expansion — this detects un-rewritten hook paths in the generated file.
  # shellcheck disable=SC2088
  if grep -q '~/.claude/scripts' "$HOOKS_JSON" 2>/dev/null; then
    _fail "hooks.json still contains ~/.claude/scripts paths (rewrite failed)"
    # shellcheck disable=SC2088
    grep '~/.claude/scripts' "$HOOKS_JSON" >&2
  else
    _ok "hooks.json: no ~/.claude/scripts paths (all rewritten)"
  fi
else
  _fail "hooks.json not found at $HOOKS_JSON"
fi

# (c) No SKILL-personal.md under skills/
if find "${TMP}/skills" -name "SKILL-personal.md" 2>/dev/null | grep -q .; then
  _fail "SKILL-personal.md found under skills/ (PII overlay not removed)"
  find "${TMP}/skills" -name "SKILL-personal.md" >&2
else
  _ok "skills/: no SKILL-personal.md (PII overlay clean)"
fi

# (d) No forbidden frontmatter in any agent
FORBIDDEN_FOUND=0
for agent_file in "${TMP}/agents/"*.md; do
  [[ -f "$agent_file" ]] || continue
  if grep -qE '^(hooks|mcpServers|permissionMode):' "$agent_file"; then
    FORBIDDEN_FOUND=$((FORBIDDEN_FOUND + 1))
    printf '[FAIL] Forbidden frontmatter in agent: %s\n' "$(basename "$agent_file")" >&2
    grep -E '^(hooks|mcpServers|permissionMode):' "$agent_file" >&2
  fi
done
if [[ "$FORBIDDEN_FOUND" -eq 0 ]]; then
  _ok "agents/: no forbidden frontmatter (hooks|mcpServers|permissionMode)"
else
  FAIL=$((FAIL + 1))
fi

# (e) Committed plugin/ artifact is not stale
# Content-hash comparison: sha256 of file content for regular files; sha256 of
# "SYMLINK:<target>" for symlinks — captures target-path drift that diff -rq misses
# (diff follows symlinks and compares resolved content; a changed target is invisible).
# Drift target: the committed plugin/ by default; overridable via CAST_PLUGIN_DIR.
COMMITTED_PLUGIN="${CAST_PLUGIN_DIR:-${REPO_ROOT}/plugin}"
if [[ -d "$COMMITTED_PLUGIN" ]]; then

  # Build a stable sorted manifest: one line per entry "<relpath> <type:f|l> <sha256>"
  # Sorted by full line so identical trees produce bit-identical manifests.
  # __pycache__/*.pyc are gitignored ephemeral bytecode (created whenever a plugin
  # python script executes); they are never committed nor emitted by gen-plugin.sh,
  # so excluding them keeps the drift check from false-firing on that transient junk.
  _build_manifest() {
    local base="${1%/}"
    {
      find "$base" -mindepth 1 -type f -not -path '*/__pycache__/*' -print0 \
        | while IFS= read -r -d '' f; do
            rel="${f#"${base}/"}"
            _chk="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
            printf '%s f %s\n' "$rel" "$_chk"
          done
      find "$base" -mindepth 1 -type l -not -path '*/__pycache__/*' -print0 \
        | while IFS= read -r -d '' l; do
            rel="${l#"${base}/"}"
            _tgt="$(readlink "$l")"
            _chk="$(printf 'SYMLINK:%s' "$_tgt" | shasum -a 256 | awk '{print $1}')"
            printf '%s l %s\n' "$rel" "$_chk"
          done
    } | sort
  }

  _MF_REGEN="$(mktemp)"
  _MF_COMMIT="$(mktemp)"
  _build_manifest "$TMP"              > "$_MF_REGEN"
  _build_manifest "$COMMITTED_PLUGIN" > "$_MF_COMMIT"

  if cmp -s "$_MF_REGEN" "$_MF_COMMIT"; then
    _ok "committed plugin/ matches regenerated output (no drift)"
  else
    _fail "committed plugin/ is STALE — regenerate and recommit: bash scripts/gen-plugin.sh \"\${REPO_ROOT}/plugin\" && git add plugin/"
    {
      # Paths only in regen (missing from committed): added
      comm -23 <(awk '{print $1}' "$_MF_REGEN" | sort) \
               <(awk '{print $1}' "$_MF_COMMIT" | sort) \
        | while IFS= read -r p; do printf '  added: %s\n' "$p"; done
      # Paths only in committed (missing from regen): removed
      comm -13 <(awk '{print $1}' "$_MF_REGEN" | sort) \
               <(awk '{print $1}' "$_MF_COMMIT" | sort) \
        | while IFS= read -r p; do printf '  removed: %s\n' "$p"; done
      # Paths in both but entry differs: changed or symlink-target-changed
      comm -12 <(awk '{print $1}' "$_MF_REGEN" | sort) \
               <(awk '{print $1}' "$_MF_COMMIT" | sort) \
        | while IFS= read -r p; do
            _rl="$(awk -v q="$p" '$1 == q {print; exit}' "$_MF_REGEN")"
            _cl="$(awk -v q="$p" '$1 == q {print; exit}' "$_MF_COMMIT")"
            [[ "$_rl" = "$_cl" ]] && continue
            _rt="$(printf '%s\n' "$_rl" | awk '{print $2}')"
            _ct="$(printf '%s\n' "$_cl" | awk '{print $2}')"
            if [[ "$_rt" = "l" && "$_ct" = "l" ]]; then
              printf '  symlink-target-changed: %s\n' "$p"
            else
              printf '  changed: %s\n' "$p"
            fi
          done
    } >&2
  fi
  rm -f "$_MF_REGEN" "$_MF_COMMIT"

else
  _fail "committed plugin/ not found at ${COMMITTED_PLUGIN}"
fi

# --- Final result ---
printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
