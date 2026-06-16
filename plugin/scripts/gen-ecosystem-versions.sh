#!/usr/bin/env bash
# gen-ecosystem-versions.sh — Generate ecosystem-versions.json for CAST ecosystem shields.io badges.
#
# Usage:
#   bash scripts/gen-ecosystem-versions.sh            # write ecosystem-versions.json (local mode)
#   bash scripts/gen-ecosystem-versions.sh --remote   # resolve versions from GitHub raw.githubusercontent
#   bash scripts/gen-ecosystem-versions.sh --check    # verify in sync, exit 0 ok / 1 drift
#   bash scripts/gen-ecosystem-versions.sh --remote --check
#
# Environment overrides:
#   CAST_ECOSYSTEM_DOC            path to docs/ecosystem.md (default: <repo_root>/docs/ecosystem.md)
#   CAST_ECOSYSTEM_ROOT           parent dir of sibling repos (default: <repo_root>/..)
#   CAST_ECOSYSTEM_VERSIONS_OUT   output file path (default: <repo_root>/ecosystem-versions.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Error logging ──────────────────────────────────────────────────────────────
_log_error() {
  local msg="$1"
  local log_dir="${HOME}/.claude/logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  printf '%s [gen-ecosystem-versions] ERROR: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" \
    >> "${log_dir}/hook-errors.log" 2>/dev/null || true
  echo "[gen-ecosystem-versions] ERROR: ${msg}" >&2
}

# ── Parse flags ────────────────────────────────────────────────────────────────
CHECK_MODE=0
REMOTE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --check)  CHECK_MODE=1 ;;
    --remote) REMOTE_MODE=1 ;;
  esac
done

# ── Resolve paths ──────────────────────────────────────────────────────────────
ECOSYSTEM_DOC="${CAST_ECOSYSTEM_DOC:-${REPO_ROOT}/docs/ecosystem.md}"
ECOSYSTEM_ROOT="${CAST_ECOSYSTEM_ROOT:-$(cd "${REPO_ROOT}/.." && pwd)}"
VERSIONS_OUT="${CAST_ECOSYSTEM_VERSIONS_OUT:-${REPO_ROOT}/ecosystem-versions.json}"

# ── Extract slugs from ecosystem.md ───────────────────────────────────────────
if [[ ! -f "$ECOSYSTEM_DOC" ]]; then
  _log_error "Ecosystem doc not found: ${ECOSYSTEM_DOC}"
  exit 1
fi

SLUGS=()
in_block=0
while IFS= read -r line; do
  if [[ "$line" == *"<!-- ECOSYSTEM_START -->"* ]]; then
    in_block=1
    continue
  fi
  if [[ "$line" == *"<!-- ECOSYSTEM_END -->"* ]]; then
    in_block=0
    continue
  fi
  if [[ "$in_block" -eq 1 ]]; then
    if [[ "$line" =~ github\.com/ek33450505/([A-Za-z0-9._-]+) ]]; then
      SLUGS+=("${BASH_REMATCH[1]}")
    fi
  fi
done < "$ECOSYSTEM_DOC"

if [[ "${#SLUGS[@]}" -eq 0 ]]; then
  _log_error "No slugs extracted from ${ECOSYSTEM_DOC} — check ECOSYSTEM_START/END markers"
  exit 1
fi

# ── Load committed value for a slug (fallback on resolution failure) ───────────
_committed_version() {
  local slug="$1"
  if [[ -f "$VERSIONS_OUT" ]]; then
    jq -r --arg k "$slug" '.[$k] // empty' < "$VERSIONS_OUT" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Version resolution helpers ────────────────────────────────────────────────
_resolve_local() {
  local slug="$1"
  local repo_dir="${ECOSYSTEM_ROOT}/${slug}"
  local ver=""
  if [[ -f "${repo_dir}/VERSION" ]]; then
    ver="$(tr -d '[:space:]' < "${repo_dir}/VERSION")"
  elif [[ -f "${repo_dir}/package.json" ]]; then
    ver="$(jq -r '.version // empty' < "${repo_dir}/package.json" 2>/dev/null || echo "")"
  fi
  echo "$ver"
}

_resolve_remote() {
  local slug="$1"
  local base="https://raw.githubusercontent.com/ek33450505/${slug}/HEAD"
  local ver=""
  ver="$(curl -fsSL --max-time 10 "${base}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "")"
  if [[ -z "$ver" ]]; then
    local pkg_json
    pkg_json="$(curl -fsSL --max-time 10 "${base}/package.json" 2>/dev/null || echo "")"
    if [[ -n "$pkg_json" ]]; then
      ver="$(echo "$pkg_json" | jq -r '.version // empty' 2>/dev/null || echo "")"
    fi
  fi
  echo "$ver"
}

# ── Plausibility check ────────────────────────────────────────────────────────
_is_valid_semver() {
  local ver="$1"
  local re='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
  [[ "$ver" =~ $re ]]
}

# ── Resolve all versions ──────────────────────────────────────────────────────
VERSIONS=()

for slug in "${SLUGS[@]}"; do
  ver=""
  if [[ "$REMOTE_MODE" -eq 1 ]]; then
    ver="$(_resolve_remote "$slug")"
  else
    ver="$(_resolve_local "$slug")"
  fi

  if [[ -z "$ver" ]]; then
    echo "[gen-ecosystem-versions] WARN: cannot resolve '${slug}', trying committed fallback" >&2
    ver="$(_committed_version "$slug")"
    if [[ -z "$ver" ]]; then
      if [[ "$CHECK_MODE" -eq 1 ]]; then
        echo "[gen-ecosystem-versions] DRIFT: '${slug}' unresolvable and absent from committed file" >&2
      else
        _log_error "Cannot resolve '${slug}' — no VERSION/package.json and no committed fallback"
      fi
      exit 1
    fi
  fi

  if ! _is_valid_semver "$ver"; then
    _log_error "Implausible version '${ver}' for '${slug}' — expected X.Y or X.Y.Z format"
    exit 1
  fi

  VERSIONS+=("$ver")
done

# ── Build JSON with jq -nS (sorted keys, deterministic) ───────────────────────
# Build iteratively: start from {} and merge each key. Hyphens in slug names are
# not valid jq variable names so we use the --arg k / ($k): $v pattern.
JSON="{}"
for i in "${!SLUGS[@]}"; do
  JSON="$(echo "$JSON" | jq -S --arg k "${SLUGS[$i]}" --arg v "${VERSIONS[$i]}" '. + {($k): $v}')"
done
JSON="$(echo "$JSON" | jq -S --arg g "scripts/gen-ecosystem-versions.sh" '. + {"_generator": $g}')"

# ── Check mode ────────────────────────────────────────────────────────────────
if [[ "$CHECK_MODE" -eq 1 ]]; then
  if [[ ! -f "$VERSIONS_OUT" ]]; then
    echo "[gen-ecosystem-versions] ERROR: ${VERSIONS_OUT} not found — run without --check to generate it" >&2
    exit 1
  fi
  COMMITTED="$(jq -S '.' < "$VERSIONS_OUT")"
  CANONICAL="$(echo "$JSON" | jq -S '.')"
  if diff_out="$(diff <(echo "$COMMITTED") <(echo "$CANONICAL"))"; then
    echo "[gen-ecosystem-versions] ecosystem-versions.json is in sync." >&2
    exit 0
  else
    echo "[gen-ecosystem-versions] DRIFT DETECTED — ecosystem-versions.json is stale:" >&2
    echo "$diff_out" >&2
    echo "" >&2
    echo "Run: bash scripts/gen-ecosystem-versions.sh  to regenerate." >&2
    exit 1
  fi
fi

# ── Write mode ────────────────────────────────────────────────────────────────
echo "$JSON" > "$VERSIONS_OUT"
echo "[gen-ecosystem-versions] wrote ${VERSIONS_OUT}" >&2
for i in "${!SLUGS[@]}"; do
  echo "  ${SLUGS[$i]}: ${VERSIONS[$i]}" >&2
done
