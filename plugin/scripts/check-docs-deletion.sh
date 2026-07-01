#!/usr/bin/env bash
# check-docs-deletion.sh — CI guard against large net deletions in append-only docs.
#
# Usage: check-docs-deletion.sh [<base-ref> [<head-ref>]]
#   base-ref  default: origin/main
#   head-ref  default: HEAD
#
# Env:
#   CAST_DOCS_DELETE_THRESHOLD  net-deleted-lines threshold per file (default: 30)
#   CAST_SKIP_DOCS_DELETE=1     skip the check entirely (escape hatch)
#   PR_BODY                     PR description text; if it contains [docs-destroy-ok]
#                               the check passes regardless of deletions.
#
# Exit codes: 0 = pass, 1 = large net deletion detected (no ack token present)

set -euo pipefail

BASE_REF="${1:-origin/main}"
HEAD_REF="${2:-HEAD}"
THRESHOLD="${CAST_DOCS_DELETE_THRESHOLD:-30}"

# Escape hatch — parallel to CAST_SKIP_PII_CHECK / CAST_SKIP_RULES_DRIFT etc.
if [[ "${CAST_SKIP_DOCS_DELETE:-}" == "1" ]]; then
  echo "[docs-destroy-guard] CAST_SKIP_DOCS_DELETE=1 — skipping check"
  exit 0
fi

ACK_TOKEN="[docs-destroy-ok]"

# ── Collect commit messages on the branch (base..head, two-dot) ───────────────
# git log with two-dot range: commits reachable from HEAD but not from base.
if git log --format="%B" "${BASE_REF}..${HEAD_REF}" -- 2>/dev/null | grep -qF "${ACK_TOKEN}"; then
  echo "[docs-destroy-guard] Ack token found in commit messages — OK"
  exit 0
fi

# Check PR_BODY env variable
if printf '%s\n' "${PR_BODY:-}" | grep -qF "${ACK_TOKEN}"; then
  echo "[docs-destroy-guard] Ack token found in PR body — OK"
  exit 0
fi

# ── Compute per-file net deletions via three-dot diff ─────────────────────────
# git diff --numstat output format: <added>  <deleted>  <path>
# Binary files print "-  -  <path>" — we skip those.
offenders=()

while IFS=$'\t' read -r added deleted path; do
  # Skip binary files (numstat prints "-" for binary)
  if [[ "$added" == "-" || "$deleted" == "-" ]]; then
    continue
  fi

  # Guard: only CHANGELOG.md (repo root) and docs/**.md (any depth)
  if [[ "$path" != "CHANGELOG.md" ]] && ! [[ "$path" =~ ^docs/.+\.md$ ]]; then
    continue
  fi

  # net deletion = deleted - added; if ≥ threshold, flag it
  net=$(( deleted - added ))
  if (( net >= THRESHOLD )); then
    offenders+=("${path}:net_deleted=${net}")
  fi
done < <(git diff --numstat "${BASE_REF}...${HEAD_REF}" -- CHANGELOG.md 'docs/**' 2>/dev/null || true)

if (( ${#offenders[@]} == 0 )); then
  echo "[docs-destroy-guard] OK — no large net deletions detected"
  exit 0
fi

# ── Offenders found, no ack token — fail ──────────────────────────────────────
{
  echo "[docs-destroy-guard] FAIL — large net deletion(s) detected in append-only docs:"
  for entry in "${offenders[@]}"; do
    file="${entry%%:*}"
    stat="${entry##*=}"
    echo "  ${file}  (net deleted: ${stat} lines, threshold: ${THRESHOLD})"
  done
  echo ""
  echo "If this deletion is intentional, add '${ACK_TOKEN}' to:"
  echo "  • A commit message on this branch, OR"
  echo "  • The PR description (PR_BODY env var)"
} >&2

exit 1
