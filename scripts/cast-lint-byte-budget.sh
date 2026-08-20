#!/usr/bin/env bash
# cast-lint-byte-budget.sh — CAST Rules-Core Size Gate (two-tier)
#
# Reports the byte footprint of the always-loaded rules surface: rules-core/*.md
# and rules-core/*.md.template. This is a TWO-TIER gate:
#   Tier 1 (advisory) — over CAST_RULES_BYTE_BUDGET prints an ADVISORY message
#     and a per-file size table, but still exits 0 (not enforced).
#   Tier 2 (hard ceiling) — over CAST_RULES_BYTE_CEILING prints a BLOCKED
#     message and per-file table, and exits non-zero (enforced), UNLESS
#     CAST_RULES_BUDGET_ACK is set to a non-empty reason string, in which case
#     it prints an ACK message (echoing the reason) and exits 0.
#
# NOTE: CLAUDE.md itself is NOT repo-tracked and is therefore excluded from
# this scan. This gate covers only the committed rules-core/ source files
# that install.sh deploys to ~/.claude/rules/.
#
# Exit codes:
#   0 — under the ceiling (regardless of advisory), or ceiling breach acked
#   1 — rules dir not found, OR ceiling breached without an ack
#
# Env overrides (for testing):
#   CAST_RULES_BYTE_BUDGET  — soft advisory target in bytes (default: 36864)
#   CAST_RULES_BYTE_CEILING — hard ceiling in bytes (default: 45056)
#   CAST_RULES_BUDGET_ACK   — non-empty reason string to ack a ceiling breach
#                             and allow it through (exit 0)
#   CAST_RULES_DIR          — path to scan instead of <repo-root>/rules-core

set -euo pipefail

BUDGET="${CAST_RULES_BYTE_BUDGET:-36864}"
CEILING="${CAST_RULES_BYTE_CEILING:-45056}"

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
	sz=$(wc -c <"${fp}" | tr -d ' ')
	TOTAL=$((TOTAL + sz))
	SIZE_LIST+=("${sz}	${fp}")
done

_print_per_file_table() {
	echo "" >&2
	echo "Per-file sizes (largest first):" >&2
	printf '%s\n' "${SIZE_LIST[@]}" | sort -rn | while IFS=$'\t' read -r sz fp; do
		printf '  %6d  %s\n' "${sz}" "$(basename "${fp}")"
	done >&2
}

# Tier 2 — hard ceiling. Must be checked BEFORE the advisory return so a
# ceiling breach can never exit 0 through the advisory path.
if [[ "${TOTAL}" -gt "${CEILING}" ]]; then
	OVERAGE=$((TOTAL - CEILING))
	if [[ -n "${CAST_RULES_BUDGET_ACK:-}" ]]; then
		echo "ACK [lint-byte-budget]: rules-core is ${TOTAL} bytes, over the ${CEILING}-byte hard ceiling by ${OVERAGE} — acknowledged: ${CAST_RULES_BUDGET_ACK}" >&2
		_print_per_file_table
		exit 0
	fi
	echo "BLOCKED [lint-byte-budget]: rules-core is ${TOTAL} bytes, over the ${CEILING}-byte hard ceiling by ${OVERAGE}. Trim rules-core, or ack with: CAST_RULES_BUDGET_ACK=\"<reason>\" bash scripts/cast-lint-byte-budget.sh" >&2
	_print_per_file_table
	exit 1
fi

# Tier 1 — advisory (report-only, never blocks)
if [[ "${TOTAL}" -gt "${BUDGET}" ]]; then
	OVERAGE=$((TOTAL - BUDGET))
	echo "ADVISORY [lint-byte-budget]: rules-core is ${TOTAL} bytes, over the ${BUDGET}-byte soft target by ${OVERAGE} — consider trimming (advisory; not enforced)" >&2
	_print_per_file_table
	exit 0
fi

echo "OK [lint-byte-budget]: ${TOTAL} bytes / ${BUDGET} bytes ($((BUDGET - TOTAL)) bytes headroom)"
exit 0
