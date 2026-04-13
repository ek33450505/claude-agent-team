#!/bin/bash
# audit-context-size.sh — count lines in always-loaded CAST context
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

total=0
echo "=== Always-loaded context line counts ==="
echo ""

# CLAUDE.md
for f in "$CLAUDE_DIR/CLAUDE.md"; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f")
  total=$((total + lines))
  printf "  %-50s %4d lines\n" "CLAUDE.md" "$lines"
done

# Rules files
echo ""
echo "  rules/"
for f in "$CLAUDE_DIR/rules/"*.md; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f")
  total=$((total + lines))
  printf "    %-48s %4d lines\n" "$(basename "$f")" "$lines"
done

echo ""
echo "  TOTAL: $total lines"
if [ "$total" -gt 500 ]; then
  echo "  WARNING: exceeds 500-line recommendation for cache hit rates"
else
  echo "  OK: within recommended limit"
fi
