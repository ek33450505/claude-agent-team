#!/usr/bin/env bash
# scripts/cast-check-skip-ledger.sh — single source of truth for the
# docs/test-skip-ledger.md drift check (call-site count AND file count).
#
# Both tests/skip-ledger-drift.bats and this script must agree on ONE
# enumeration, not two independently-maintained copies of the same policy
# (the exact class of bug fixed for gen-plugin.sh earlier in v10).
#
# Usage:
#   scripts/cast-check-skip-ledger.sh [--help]
#
# Env:
#   CAST_SKIP_LEDGER_PATH  — override the ledger path (default: <repo>/docs/test-skip-ledger.md)
#                            Used by tests to point at a fixture instead of the tracked ledger.
#
# Exit codes:
#   0  — recorded call-site count AND file count match the actual enumeration
#   1  — drift detected (call sites and/or files), or the ledger is missing/unparseable
#   2  — usage error: an unrecognised argument was passed
set -euo pipefail

_usage() {
	cat <<'EOF'
Usage: cast-check-skip-ledger.sh [--help]

Verifies that docs/test-skip-ledger.md's recorded "Total call sites: N across
M files" line matches the actual skip-site enumeration in tests/*.bats.

Env:
  CAST_SKIP_LEDGER_PATH  Override the ledger path (default: <repo>/docs/test-skip-ledger.md)

Exit codes:
  0  in sync
  1  drift detected, or ledger missing/unparseable
  2  usage error: an unrecognised argument was passed
EOF
}

if [[ "${1:-}" == "--help" ]]; then
	_usage
	exit 0
fi

if [[ $# -gt 0 ]]; then
	echo "cast-check-skip-ledger: unrecognised argument: $1" >&2
	_usage >&2
	exit 2
fi

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$_script_dir" rev-parse --show-toplevel 2>/dev/null)" || {
	echo "cast-check-skip-ledger: FATAL — ${_script_dir} is not inside a git repository" >&2
	exit 1
}

LEDGER="${CAST_SKIP_LEDGER_PATH:-$REPO/docs/test-skip-ledger.md}"

if [[ ! -f "$LEDGER" ]]; then
	echo "cast-check-skip-ledger: FATAL — ledger not found at $LEDGER" >&2
	exit 1
fi

# Canonical enumeration — this script is the single source of truth for it.
# tests/skip-ledger-drift.bats and .githooks/pre-push both delegate here
# rather than re-implementing it. Catches all 4 skip forms: || skip "..." /
# && skip "..." / line-leading skip "..." / if-then inline skip "...".
# Excludes comment lines and this guard's own test file.
actual_sites=$(grep -rEn '(\|\| skip "|&& skip "|[[:space:]]skip ")' \
	"$REPO/tests/" --include="*.bats" |
	grep -vF 'skip-ledger-drift.bats' |
	grep -cvE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
actual_sites=$(echo "$actual_sites" | tr -d ' ')

actual_files=$(grep -rlE '(\|\| skip "|&& skip "|[[:space:]]skip ")' \
	"$REPO/tests/" --include="*.bats" |
	grep -vFc 'skip-ledger-drift.bats' || true)
actual_files=$(echo "$actual_files" | tr -d ' ')

# Anchor must be unique in the ledger — the combined form so the historical
# "prior count of 23 across 14 files" prose note (which lacks the "Total
# call sites:" prefix) cannot be matched instead.
mapfile -t matches < <(grep -oE 'Total call sites: [0-9]+\*\* across [0-9]+ files' "$LEDGER")

if [[ "${#matches[@]}" -eq 0 ]]; then
	echo "cast-check-skip-ledger: FATAL — no 'Total call sites: N** across M files' anchor found in $LEDGER" >&2
	exit 1
fi
if [[ "${#matches[@]}" -gt 1 ]]; then
	echo "cast-check-skip-ledger: FATAL — anchor matched ${#matches[@]} times in $LEDGER (expected exactly 1); refusing to silently take the first" >&2
	printf '  %s\n' "${matches[@]}" >&2
	exit 1
fi

recorded_line="${matches[0]}"
recorded_sites=$(grep -oE '[0-9]+' <<<"$recorded_line" | sed -n '1p')
recorded_files=$(grep -oE '[0-9]+' <<<"$recorded_line" | sed -n '2p')

if [[ -z "$recorded_sites" || -z "$recorded_files" ]]; then
	echo "cast-check-skip-ledger: FATAL — could not parse both numbers from anchor: $recorded_line" >&2
	exit 1
fi

drift=0

if [[ "$actual_sites" -ne "$recorded_sites" ]]; then
	echo "DRIFT: call-site count — ledger records $recorded_sites, actual enumeration found $actual_sites"
	drift=1
fi

if [[ "$actual_files" -ne "$recorded_files" ]]; then
	echo "DRIFT: file count — ledger records $recorded_files, actual enumeration found $actual_files"
	drift=1
fi

if [[ "$drift" -eq 1 ]]; then
	exit 1
fi

echo "OK: skip ledger in sync — $actual_sites call sites across $actual_files files"
exit 0
