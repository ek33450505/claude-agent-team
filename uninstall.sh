#!/bin/bash
# uninstall.sh — Remove CAST (Claude Agent Specialist Team) installation
# Does NOT remove: ~/.claude/rules/, ~/.claude/plans/,
#                  ~/.claude/agent-memory-local/, ~/.claude/task-board.json

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CAST_BASE="$HOME/.claude"

echo -e "${RED}WARNING: CAST Uninstall${NC}"
echo ""
echo "This will remove the following from ${CAST_BASE}:"
echo "  - agents/"
echo "  - commands/"
echo "  - scripts/"
echo "  - skills/"
echo "  - cast-version"
echo "  - agent-status/"
echo ""
echo -e "${YELLOW}The following will NOT be removed:${NC}"
echo "  - rules/"
echo "  - plans/"
echo "  - agent-memory-local/"
echo "  - task-board.json"
echo ""
read -r -p "Are you sure you want to uninstall CAST? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

# Create timestamped backup
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.claude/backups/uninstall-${TIMESTAMP}"

echo ""
echo -e "${YELLOW}Creating backup at: ${BACKUP_DIR}${NC}"
mkdir -p "$BACKUP_DIR"

for dir in agents commands scripts skills; do
  if [[ -d "${CAST_BASE}/${dir}" ]]; then
    cp -r "${CAST_BASE}/${dir}" "${BACKUP_DIR}/${dir}"
    echo "  Backed up: ${dir}/"
  fi
done

echo -e "${GREEN}Backup complete.${NC}"
echo ""

# Remove CAST components — each path is checked before rm -rf
TARGETS=(
  "${CAST_BASE}/agents"
  "${CAST_BASE}/commands"
  "${CAST_BASE}/scripts"
  "${CAST_BASE}/skills"
  "${CAST_BASE}/cast-version"
  "${CAST_BASE}/agent-status"
)

for target in "${TARGETS[@]}"; do
  # Bound-check: only remove paths under ~/.claude/
  if [[ "$target" != "$HOME/.claude/"* ]]; then
    echo -e "${RED}SKIPPED (safety check failed): ${target}${NC}"
    continue
  fi
  if [[ -e "$target" || -d "$target" ]]; then
    rm -rf "$target"
    echo "  Removed: ${target}"
  fi
done

echo ""
echo -e "${GREEN}CAST uninstall complete.${NC}"
echo ""
echo "Backup saved to: ${BACKUP_DIR}"
echo ""
echo "To reinstall CAST, run:"
echo "  bash <path-to-repo>/install.sh"
echo "  or clone: https://github.com/yourusername/claude-agent-team"
