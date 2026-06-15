#!/usr/bin/env bash
# gen-arch-diagram.sh — Render the CAST Mermaid source to SVG.
#
# Usage:
#   bash scripts/gen-arch-diagram.sh
#
# Input:  docs/architecture/cast-architecture.mmd  (source of truth — do NOT edit)
# Output: docs/architecture/cast-architecture.svg  (replaced in-place on success)
#
# Requires npx (Node.js ≥ 16).  The first run downloads @mermaid-js/mermaid-cli
# and Chromium via puppeteer — allow ~2 min on a cold cache.
# Exits 1 on any failure; the existing SVG is never touched on failure.

set -euo pipefail

# --- Resolve repo root ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MMD_IN="${REPO_ROOT}/docs/architecture/cast-architecture.mmd"
SVG_OUT="${REPO_ROOT}/docs/architecture/cast-architecture.svg"

# --- Pre-flight checks ---
if ! command -v npx >/dev/null 2>&1; then
  printf 'ERROR: npx not found. Install Node.js ≥ 16 and re-run.\n' >&2
  exit 1
fi

if [[ ! -f "$MMD_IN" ]]; then
  printf 'ERROR: Mermaid source not found: %s\n' "$MMD_IN" >&2
  exit 1
fi

# --- Write temp puppeteer config (no-sandbox for CI) ---
TMPDIR_LOCAL="$(mktemp -d)"
PUPPETEER_CFG="${TMPDIR_LOCAL}/puppeteer-cfg.json"
cat > "$PUPPETEER_CFG" <<'EOF'
{"args":["--no-sandbox","--disable-setuid-sandbox"]}
EOF

cleanup() {
  rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT

# --- Render to a temp file first; only replace on success ---
SVG_TMP="${TMPDIR_LOCAL}/cast-architecture.svg"

printf 'Rendering %s → %s\n' "$MMD_IN" "$SVG_OUT"

if ! npx -y @mermaid-js/mermaid-cli@latest \
      -i "$MMD_IN" \
      -o "$SVG_TMP" \
      -b transparent \
      --puppeteerConfigFile "$PUPPETEER_CFG" 2>&1; then
  printf 'ERROR: mermaid-cli render failed. Existing SVG unchanged.\n' >&2
  exit 1
fi

if [[ ! -s "$SVG_TMP" ]]; then
  printf 'ERROR: mermaid-cli produced an empty SVG. Existing SVG unchanged.\n' >&2
  exit 1
fi

# --- Atomic replace ---
mv "$SVG_TMP" "$SVG_OUT"

printf 'Done. SVG written to: %s\n' "$SVG_OUT"
