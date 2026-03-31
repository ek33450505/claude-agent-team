#!/bin/bash
# cast-memory-backup.sh — Backup agent memory to a private GitHub release
#
# Usage:
#   bash cast-memory-backup.sh          # full backup + push to GitHub
#   bash cast-memory-backup.sh --dry-run # create tarball only, skip gh release push
#
# Cron (daily at 02:00):
#   0 2 * * * /bin/bash ~/Projects/personal/claude-agent-team/scripts/cast-memory-backup.sh >> ~/.claude/logs/memory-backup.log 2>&1
#
# iCloud Sync (manual step — do NOT automate):
#   If iCloud Drive is active, you can symlink the memory directory for sync:
#   ln -s ~/.claude/agent-memory-local ~/Library/Mobile\ Documents/com~apple~CloudDocs/cast-memory
#   WARNING: iCloud symlinks can cause issues with git. Do not add this symlink to the repo.
#
# Backup destination: GitHub release on ek33450505/cast-memory-backup
# Log file: ~/.claude/logs/memory-backup.log

set -euo pipefail

DATE=$(date +%Y%m%d)
MEMORY_DIR="${HOME}/.claude/agent-memory-local"
BACKUP_DIR="${CAST_BACKUP_DIR:-/tmp}"
BACKUP_FILE="${BACKUP_DIR}/cast-memory-backup-${DATE}.tar.gz"
BACKUP_REPO="ek33450505/cast-memory-backup"
LOG_FILE="${HOME}/.claude/logs/memory-backup.log"
DRY_RUN=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Verify source directory exists
if [[ ! -d "$MEMORY_DIR" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Memory directory not found: $MEMORY_DIR" | tee -a "$LOG_FILE"
  exit 1
fi

# Create tarball
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Creating backup: $BACKUP_FILE" | tee -a "$LOG_FILE"
tar -czf "$BACKUP_FILE" -C "${HOME}/.claude" agent-memory-local/

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Tarball creation failed" | tee -a "$LOG_FILE"
  exit 1
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Tarball created: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))" | tee -a "$LOG_FILE"

# Dry-run: stop here, skip gh push
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Skipping gh release push. Tarball at: $BACKUP_FILE" | tee -a "$LOG_FILE"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Would push to repo: $BACKUP_REPO as release backup-${DATE}" | tee -a "$LOG_FILE"
  # Verify tarball contents
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Tarball contents:" | tee -a "$LOG_FILE"
  tar -tzf "$BACKUP_FILE" | head -20 | tee -a "$LOG_FILE"
  exit 0
fi

# Push to GitHub release
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pushing to GitHub release backup-${DATE} on ${BACKUP_REPO}" | tee -a "$LOG_FILE"
gh release create "backup-${DATE}" "$BACKUP_FILE" \
  --repo "$BACKUP_REPO" \
  --title "Memory backup ${DATE}" \
  --notes "Automated CAST agent memory backup" \
  2>&1 | tee -a "$LOG_FILE"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backup complete: $BACKUP_FILE" | tee -a "$LOG_FILE"
