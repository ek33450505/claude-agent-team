#!/usr/bin/env bash
# blast-radius-lint.sh — Ratchet: any bare rm -rf or shutil.rmtree in scripts/ is a violation.
#
# RULE (Ed-approved amendment to design doc Q6):
#   ANY occurrence of bare rm -rf (or permutations) or shutil.rmtree in scripts/ is a
#   violation, with NO "preceded-by-guard-within-5-lines" parsing.
#   Exemptions only via the EXEMPTIONS or ALLOWLIST arrays below.
#
# RM PERMUTATIONS CAUGHT (recursive + force, any order/clustering):
#   rm -rf, rm -fr, rm -Rf, rm -fR, rm -r -f, rm -f -r,
#   rm --recursive --force, rm --force --recursive.
#   rm -f alone (no recursive) and rm -r alone (no force) are NOT flagged today.
#   Bare rm -r (no force) noted as a possible future ratchet widening.
#   Pattern anchored with (^|[^[:alpha:]]) — words ending in 'rm' (confirm, alarm) are safe.
#
# EXEMPTIONS (a): the guard primitives themselves (rm/rmtree lives there by design)
# ALLOWLIST (b): guarded legacy callsites deferred to T7 migration
#
# Skip logic:
#   - Allowlisted/exempted files are skipped entirely
#   - Lines whose first non-space character is # (pure comment lines) are skipped
#
# Comment-handling stance (FAIL-CLOSED): pure comment lines (first non-space char = #)
#   are skipped — they cannot execute. Lines WITH CODE that also mention an rm-rf-class
#   call in a trailing comment ARE flagged; position-of-# heuristics are bypassable
#   (e.g. `true "#"; rm -rf /x` slips past comment-skip without a real shell parser).
#   Reword the comment or add to ALLOWLIST if the code line is legitimately safe.
#
# Exit 0: clean (no violations)
# Exit 1: violations found — prints file:line listing to stdout
#
# CAST_LINT_SCRIPTS_DIR env var overrides the scripts directory (for testing).

set -euo pipefail

# F4(a): correct two-step assignment — OR operator ensures fallback only when git fails
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="${CAST_LINT_SCRIPTS_DIR:-${REPO_ROOT}/scripts}"

# ── Exemptions (a): guard primitives — the protected rm/rmtree lives here ───
EXEMPTIONS=(
  "cast-guard-lib.sh"  # Shell guard primitive: contains the authoritative recursive-delete
  "cast_guard.py"      # Python guard primitive: contains the authoritative rmtree call
)

# ── Allowlist (b): guarded legacy callsites ──────────────────────────────────
ALLOWLIST=(
  # Safe: rm -rf in EXIT trap on its own mktemp -d — low-risk self-contained pattern
  "ci-pii-scan.sh"
)

_is_exempt_or_allowed() {
  local basename_arg="$1"
  local item
  for item in "${EXEMPTIONS[@]}" "${ALLOWLIST[@]}"; do
    [[ "$basename_arg" == "$item" ]] && return 0
  done
  return 1
}

# F4(b): hermetic zero-file sanity check — a lint that scans nothing must never pass
scan_count=0
for _f in "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py; do
  [[ -f "$_f" ]] && scan_count=$((scan_count + 1))
done
if [[ "$scan_count" -eq 0 ]]; then
  echo "ERROR [blast-radius-lint]: scanned 0 files in '${SCRIPTS_DIR}' — refusing to pass on empty input"
  exit 1
fi

violations=0
declare -a violation_lines=()

# F2: rm-rf-class pattern — catches rm carrying BOTH recursive (r/R/--recursive) and
# force (f/--force) in any flag order or clustering. BSD grep compatible (no \b or GNU
# syntax). Anchored with (^|[^[:alpha:]]) to skip words ending in 'rm' (confirm, alarm).
RM_RF_PATTERN='(^|[^[:alpha:]])rm[[:space:]]+(-[[:alpha:]]*[rR][[:alpha:]]*[fF][[:alpha:]]*|-[[:alpha:]]*[fF][[:alpha:]]*[rR][[:alpha:]]*|--recursive[[:space:]]+--force|--force[[:space:]]+--recursive|-[rR][[:space:]]+-[fF]|-[fF][[:space:]]+-[rR])'

# Grep for rm-rf-class calls and shutil.rmtree across .sh and .py files in the scripts
# directory (non-recursive into subdirectories — scripts/ is flat).
while IFS=: read -r file lineno content; do
  # Skip if the file itself is exempted or allowlisted
  local_basename="$(basename "$file")"
  _is_exempt_or_allowed "$local_basename" && continue

  # Skip pure comment lines: strip leading whitespace, check if first char is #
  stripped="${content#"${content%%[^[:space:]]*}"}"
  [[ "${stripped:0:1}" == "#" ]] && continue

  violation_lines+=("  ${file}:${lineno}: ${content}")
  violations=$((violations + 1))
done < <(grep -nE "${RM_RF_PATTERN}|shutil\.rmtree" \
           "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null \
         | grep -v '^Binary' || true)

if [[ "${violations}" -gt 0 ]]; then
  echo "ERROR [blast-radius-lint]: ${violations} bare destructive call(s) found in scripts/:"
  for line in "${violation_lines[@]}"; do
    echo "$line"
  done
  echo ""
  echo "  Rule: every recursive force-delete (rm-rf-class) or rmtree call must use cast_safe_rm (shell)"
  echo "        or safe_rmtree (Python) from the blast-radius guard primitives."
  echo "  To add a new exemption, append to ALLOWLIST in scripts/blast-radius-lint.sh"
  echo "  with a comment explaining the guard mechanism."
  exit 1
fi

echo "[blast-radius-lint] OK — no bare destructive calls in scripts/"
exit 0
