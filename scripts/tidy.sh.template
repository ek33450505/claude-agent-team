# TEMPLATE: Configure the paths below to match your directory structure.
#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  tidy.sh — Smart Home Directory Hygiene Script      ║
# ║  Run manually or schedule with launchd/cron         ║
# ╚══════════════════════════════════════════════════════╝
set -uo pipefail

HOME_DIR="$HOME"
DOWNLOADS="$HOME_DIR/Downloads"
DESKTOP="$HOME_DIR/Desktop"
SCREENSHOTS="$HOME_DIR/Pictures/Screenshots"
DOCUMENTS="$HOME_DIR/Documents"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       🧹  Home Directory Tidy        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

MOVED=0
DELETED=0

# ── 1. Auto-route Desktop screenshots to Pictures/Screenshots ──
mkdir -p "$SCREENSHOTS"
for f in "$DESKTOP"/Screenshot*.png "$DESKTOP"/Screen\ Recording*.mov; do
    [ -e "$f" ] || continue
    mv "$f" "$SCREENSHOTS/"
    echo -e "${GREEN}  ✓ Screenshot → Pictures/Screenshots/$(basename "$f")${NC}"
    ((MOVED++))
done

# ── 2. Clean Word temp/lock files (~$*) anywhere in Documents ──
find "$HOME_DIR/Documents" -name '~\$*' -type f 2>/dev/null | while read -r f; do
    rm "$f"
    echo -e "${YELLOW}  ✗ Deleted temp file: $(basename "$f")${NC}"
    ((DELETED++)) || true
done

# ── 3. Clean .DS_Store files (Finder recreates them as needed) ──
find "$HOME_DIR/Documents" "$HOME_DIR/Desktop" "$HOME_DIR/Downloads" \
    -name '.DS_Store' -type f -delete 2>/dev/null
echo -e "${YELLOW}  ✗ Cleaned .DS_Store files${NC}"

# ── 4. Flag Downloads older than 30 days ──
echo ""
echo -e "${CYAN}  ── Stale Downloads (>30 days) ──${NC}"
STALE=$(find "$DOWNLOADS" -maxdepth 1 -not -name '.*' -mtime +30 -type f 2>/dev/null)
if [ -n "$STALE" ]; then
    echo "$STALE" | while read -r f; do
        echo -e "${YELLOW}  ⚠  $(basename "$f") — $(stat -f '%Sm' -t '%Y-%m-%d' "$f")${NC}"
    done
else
    echo -e "${GREEN}  ✓ Downloads folder is clean${NC}"
fi

# ── 5. Flag orphaned venvs in home directory ──
echo ""
echo -e "${CYAN}  ── Orphaned Virtualenvs ──${NC}"
VENVS=$(find "$HOME_DIR" -maxdepth 2 -name 'pyvenv.cfg' -not -path '*/Projects/*' 2>/dev/null || true)
if [ -n "$VENVS" ]; then
    echo "$VENVS" | while read -r f; do
        echo -e "${YELLOW}  ⚠  $(dirname "$f")${NC}"
    done
else
    echo -e "${GREEN}  ✓ No orphaned virtualenvs${NC}"
fi

# ── Summary ──
echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${GREEN}  Done. Moved: $MOVED | Deleted: $DELETED${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"
