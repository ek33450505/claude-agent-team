#!/usr/bin/env bash
# cast-lint-byte-budget.sh — CAST Byte Budget Gate
#
# Enforces a byte budget on the always-loaded rules surface: rules-core/*.md
# and rules-core/*.md.template.
#
# NOTE: CLAUDE.md itself is NOT repo-tracked and is therefore excluded from
# this scan. This gate covers only the committed rules-core/ source files that
# install.sh deploys to ~/.claude/rules/.
#
# Exit codes:
#   0 — total bytes within budget
#   1 — total bytes exceed budget
#
# Env overrides (for testing):
#   CAST_RULES_BYTE_BUDGET  — byte threshold (default: 20480)
#   CAST_RULES_DIR          — path to scan instead of <repo-root>/rules-core

set -euo pipefail

BUDGET="${CAST_RULES_BYTE_BUDGET:-20480}"

# Resolve repo root if CAST_RULES_DIR is not overridden
if [[ -n "${CAST_RULES_DIR:-}" ]]; then
  RULES_DIR="${CAST_RULES_DIR}"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  RULES_DIR="${REPO_ROOT}/rules-core"
fi

if [[ ! -d "${RULES_DIR}" ]]; then
  echo "ERROR [lint-byte-budget]: rules dir not found: ${RULES_DIR}" >&2
  exit 1
fi

# Collect matching files (.md and .md.template)
# bash-3.2 compatible (macOS CI): mapfile/readarray are bash-4+ only
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(find "${RULES_DIR}" -maxdepth 1 -type f \( -name "*.md" -o -name "*.md.template" \) | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "WARNING [lint-byte-budget]: no *.md or *.md.template files found in ${RULES_DIR}" >&2
  exit 0
fi

TOTAL=0
declare -a SIZE_LIST=()

for fp in "${FILES[@]}"; do
  sz=$(wc -c < "${fp}" | tr -d ' ')
  TOTAL=$(( TOTAL + sz ))
  SIZE_LIST+=( "${sz}	${fp}" )
done

if [[ "${TOTAL}" -gt "${BUDGET}" ]]; then
  echo "ERROR [lint-byte-budget]: rules-core exceeds byte budget: ${TOTAL} bytes > ${BUDGET} bytes"
  echo ""
  echo "Per-file sizes (largest first):"
  printf '%s\n' "${SIZE_LIST[@]}" | sort -rn | while IFS=$'\t' read -r sz fp; do
    printf '  %6d  %s\n' "${sz}" "$(basename "${fp}")"
  done
  exit 1
fi

echo "OK [lint-byte-budget]: ${TOTAL} bytes / ${BUDGET} bytes ($(( BUDGET - TOTAL )) bytes headroom)"
exit 0
