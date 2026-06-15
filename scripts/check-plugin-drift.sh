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

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
GEN_SCRIPT="${REPO_ROOT}/scripts/gen-plugin.sh"

# Load the cast-guard-lib for safe destructive operations (data-integrity pillar)
# shellcheck source=cast-guard-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/cast-guard-lib.sh" 2>/dev/null \
  || source "${CAST_SCRIPTS_DIR:-${HOME}/.claude/scripts}/cast-guard-lib.sh" 2>/dev/null \
  || true
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
bash "$GEN_SCRIPT" "$TMP" 2>/dev/null || true

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

# (e) Committed plugin/ artifact is not stale (byte-identical to a fresh regeneration)
# Drift target: the committed plugin/ by default; overridable for hermetic testing.
COMMITTED_PLUGIN="${CAST_PLUGIN_DIR:-${REPO_ROOT}/plugin}"
if [[ -d "$COMMITTED_PLUGIN" ]]; then
  if diff -rq "$TMP" "$COMMITTED_PLUGIN" >/dev/null 2>&1; then
    _ok "committed plugin/ matches regenerated output (no drift)"
  else
    _fail "committed plugin/ is STALE — regenerate and recommit: bash scripts/gen-plugin.sh \"\${REPO_ROOT}/plugin\" && git add plugin/"
    diff -rq "$TMP" "$COMMITTED_PLUGIN" >&2 || true
  fi
else
  _fail "committed plugin/ not found at ${COMMITTED_PLUGIN}"
fi

# --- Final result ---
printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
