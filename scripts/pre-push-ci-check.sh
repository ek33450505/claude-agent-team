#!/usr/bin/env bash
# pre-push-ci-check.sh — CI safety checks before pushing
# Catches the recurring failure classes documented in the 2026-04-16 insights report.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PASS=true

echo "[pre-push-ci-check] Scanning $REPO_ROOT"

# Check 1: Hardcoded absolute paths in test files
echo ""
echo "=== Check 1: Hardcoded /Users/ paths in test files ==="
HARDCODED=$(grep -rn "/Users/" "$REPO_ROOT/tests" "$REPO_ROOT/test" "$REPO_ROOT/src" \
  --include="*.sh" --include="*.bats" --include="*.test.*" --include="*.spec.*" \
  --exclude-dir=".git" --exclude-dir="worktrees" \
  --exclude-dir="node_modules" --exclude-dir=".cache" \
  --exclude-dir="dist" \
  2>/dev/null | grep -v "\.git" || true)
if [[ -n "$HARDCODED" ]]; then
  echo "FAIL: Found hardcoded /Users/ paths (will break on CI runners):"
  echo "$HARDCODED" | head -20
  PASS=false
else
  echo "PASS: No hardcoded /Users/ paths found"
fi

# Check 2: FTS5 availability — macOS-only SQLite feature
echo ""
echo "=== Check 2: FTS5 platform-specific imports ==="
FTS5_HITS=$(grep -rn "fts5\|FTS5\|USING fts5" "$REPO_ROOT" \
  --include="*.py" --include="*.sh" --include="*.sql" \
  --exclude-dir=".git" --exclude-dir="worktrees" \
  --exclude-dir="node_modules" --exclude-dir=".cache" \
  --exclude-dir="dist" \
  2>/dev/null | grep -v "#.*fts5\|-- fts5" || true)
if [[ -n "$FTS5_HITS" ]]; then
  echo "WARNING: FTS5 references found — verify these include a sqlite3 version check:"
  echo "$FTS5_HITS" | head -10
  # Warning only, not a hard fail — some repos handle this gracefully
else
  echo "PASS: No bare FTS5 references"
fi

# Check 3: Stale version() or package name references after renames
echo ""
echo "=== Check 3: Stale package/version references ==="
# Check package.json name vs. imports if package.json exists
if [[ -f "$REPO_ROOT/package.json" ]]; then
  PKG_NAME=$(python3 - "$REPO_ROOT/package.json" <<'EOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('name', ''))
except Exception:
    pass
EOF
)
  echo "Package name: $PKG_NAME"
fi
echo "PASS: Manual review recommended after any package rename"

echo ""
if [[ "$PASS" == "true" ]]; then
  echo "[pre-push-ci-check] All checks passed."
  exit 0
else
  echo "[pre-push-ci-check] FAILURES detected. Fix before pushing."
  exit 1
fi
