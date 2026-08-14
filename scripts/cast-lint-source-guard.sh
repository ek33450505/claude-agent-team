#!/usr/bin/env bash
# cast-lint-source-guard.sh — Ratchet: a bare `source`/`.` statement used as the
# LEFT operand of `||` in a file that runs under `set -e` is a violation.
#
# BUG CLASS: under `set -e`, Apple's frozen /bin/bash 3.2 (still what a plain
# `bash` resolves to on stock macOS/CI runners unless a newer bash is first on
# PATH) treats `source`/`.` of a MISSING file as fatal EVEN as the left operand
# of `||`, aborting the whole script instead of falling through to the `|| ...`
# fallback. bash 4+ does not have this bug. Every `source X 2>/dev/null || Y`
# written for graceful degradation does the exact opposite on bash 3.2.
#
# SAFE patterns (NOT flagged):
#   (a) Existence-guarded — source only ever attempted on a path already
#       confirmed to exist, so the missing-file failure mode can't trigger:
#         if [[ -f "$path" ]]; then source "$path" 2>/dev/null || true; fi
#   (b) Subshell-wrapped — the bare `source` builtin is never itself the left
#       operand of the outer `||`; the SUBSHELL is, and a subshell failing is
#       not subject to the 3.2 bug:
#         ( source "$path" 2>/dev/null && cmd ) || true
#
# VIOLATION (flagged): a `source`/`.` statement that is the first token of its
# logical line (i.e. a bare top-level statement — not wrapped in `( ... )`),
# whose line contains `||`, and which is not inside an `if [[ -f ... ]]; then`
# guard's true-branch, in a file that contains `set -e` / `set -euo pipefail`
# anywhere.
#
# Detection is line-based (bash while-read + a one-level if/else/fi state
# machine), not a real shell parser — consistent with blast-radius-lint.sh's
# stance. Known limits (documented rather than silently wrong):
#   - Only a single level of if/else/fi nesting is tracked; a guard nested
#     inside an unrelated if/fi may confuse the state machine.
#   - A `source` statement chained after `;` on the same logical line as other
#     code (e.g. `foo=$(...); source X || true`) is not detected — the check
#     only inspects the line's first token.
#   - Backslash line-continuations ARE joined into one logical line first, so
#     the historical multi-line `source X \` / `|| source Y \` form IS caught.
#
# CAST_LINT_SCRIPTS_DIR env var overrides the scanned directory (for testing).
#
# Exit 0: clean (no violations). Exit 1: violations found — file:line listing.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="${CAST_LINT_SCRIPTS_DIR:-${REPO_ROOT}/scripts}"

# Hermetic zero-file sanity check — a lint that scans nothing must never pass.
scan_count=0
for _f in "$SCRIPTS_DIR"/*.sh; do
  [[ -f "$_f" ]] && scan_count=$((scan_count + 1))
done
if [[ "$scan_count" -eq 0 ]]; then
  echo "ERROR [cast-lint-source-guard]: scanned 0 files in '${SCRIPTS_DIR}' — refusing to pass on empty input"
  exit 1
fi

violations=0
declare -a violation_lines=()

_scan_file() {
  local file="$1"
  local lineno=0 logical_line="" logical_start=0 guard_state=0 stripped first_word

  # Only files that opt into errexit anywhere can hit the bug — cheap pre-filter.
  grep -qE '(^|[^[:alnum:]_])set[[:space:]]+-[a-zA-Z]*e' "$file" 2>/dev/null || return 0

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    lineno=$((lineno + 1))
    [[ -z "$logical_line" ]] && logical_start=$lineno

    if [[ "$raw_line" == *'\' ]]; then
      # Continuation line — strip trailing backslash, accumulate, keep reading.
      logical_line+="${raw_line%\\} "
      continue
    fi
    logical_line+="$raw_line"

    # Strip leading whitespace (blast-radius-lint.sh idiom).
    stripped="${logical_line#"${logical_line%%[^[:space:]]*}"}"

    # Pure comment lines never execute — skip (fail-closed stance mirrors
    # blast-radius-lint.sh; see header for the bypassable-heuristic caveat).
    if [[ "${stripped:0:1}" != "#" ]]; then
      # One-level if/else/fi state machine for the existence-guard's true-branch.
      if [[ "$stripped" =~ ^if[[:space:]]+\[\[[[:space:]]+-f[[:space:]] ]]; then
        guard_state=1
      elif [[ "$stripped" =~ ^else([[:space:]]|$) ]]; then
        [[ "$guard_state" -eq 1 ]] && guard_state=2
      elif [[ "$stripped" =~ ^fi([[:space:]]|$) ]]; then
        guard_state=0
      fi

      if [[ "$guard_state" -ne 1 && "$stripped" == *'||'* ]]; then
        first_word="${stripped%% *}"
        if [[ "$first_word" == "source" || "$first_word" == "." ]]; then
          violations=$((violations + 1))
          violation_lines+=("  ${file}:${logical_start}: ${logical_line}")
        fi
      fi
    fi

    logical_line=""
  done < "$file"
}

for f in "$SCRIPTS_DIR"/*.sh; do
  [[ -f "$f" ]] || continue
  _scan_file "$f"
done

if [[ "${violations}" -gt 0 ]]; then
  echo "ERROR [cast-lint-source-guard]: ${violations} unguarded source-under-set-e call(s) found:"
  for line in "${violation_lines[@]}"; do
    echo "$line"
  done
  echo ""
  echo "  Rule: under set -e, bash 3.2 treats \`source\` of a missing file as fatal even"
  echo "        left-of-\`||\`. Guard with [[ -f \"\$path\" ]] before sourcing, or wrap in a"
  echo "        subshell: ( source \"\$path\" && ... ) || true. See scripts/cast-guard-lib.sh"
  echo "        header for the canonical pattern."
  exit 1
fi

echo "[cast-lint-source-guard] OK — no unguarded source-under-set-e calls in ${SCRIPTS_DIR}"
exit 0
