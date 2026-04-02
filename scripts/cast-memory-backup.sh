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
# H2: Additional backup targets
DB_BACKUP_FILE="${BACKUP_DIR}/cast-db-backup-${DATE}.sqlite"
PLANS_BACKUP_FILE="${BACKUP_DIR}/cast-plans-backup-${DATE}.tar.gz"
AUTOMEMORY_BACKUP_FILE="${BACKUP_DIR}/cast-auto-memory-backup-${DATE}.tar.gz"
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

# Create tarball (agent-memory-local/)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Creating backup: $BACKUP_FILE" | tee -a "$LOG_FILE"
tar -czf "$BACKUP_FILE" -C "${HOME}/.claude" agent-memory-local/

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Tarball creation failed" | tee -a "$LOG_FILE"
  exit 1
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Tarball created: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))" | tee -a "$LOG_FILE"

# H2: Backup cast.db via SQLite online backup (safe for live DB)
DB_PATH="${HOME}/.claude/cast.db"
if [[ -f "$DB_PATH" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backing up cast.db → $DB_BACKUP_FILE" | tee -a "$LOG_FILE"
  sqlite3 "$DB_PATH" ".backup '$DB_BACKUP_FILE'" 2>/dev/null || true
  if [[ -f "$DB_BACKUP_FILE" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cast.db backup created ($(du -sh "$DB_BACKUP_FILE" | cut -f1))" | tee -a "$LOG_FILE"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN: cast.db backup not created (DB may be empty or sqlite3 unavailable)" | tee -a "$LOG_FILE"
  fi
fi

# H2: Backup ~/.claude/plans/
PLANS_DIR="${HOME}/.claude/plans"
if [[ -d "$PLANS_DIR" ]] && [[ "$(ls -A "$PLANS_DIR" 2>/dev/null)" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backing up plans/ → $PLANS_BACKUP_FILE" | tee -a "$LOG_FILE"
  tar -czf "$PLANS_BACKUP_FILE" -C "${HOME}/.claude" plans/ 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] plans/ backup created ($(du -sh "$PLANS_BACKUP_FILE" 2>/dev/null | cut -f1))" | tee -a "$LOG_FILE"
fi

# H2: Backup ~/.claude/projects/*/memory/ (auto-memory)
PROJECTS_DIR="${HOME}/.claude/projects"
if [[ -d "$PROJECTS_DIR" ]]; then
  MEMORY_PATHS=$(find "$PROJECTS_DIR" -type d -name "memory" 2>/dev/null | head -50)
  if [[ -n "$MEMORY_PATHS" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backing up auto-memory → $AUTOMEMORY_BACKUP_FILE" | tee -a "$LOG_FILE"
    tar -czf "$AUTOMEMORY_BACKUP_FILE" -C "${HOME}/.claude" projects/ 2>/dev/null || true
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] auto-memory backup created ($(du -sh "$AUTOMEMORY_BACKUP_FILE" 2>/dev/null | cut -f1))" | tee -a "$LOG_FILE"
  fi
fi

# Dry-run: stop here, skip gh push
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Skipping gh release push." | tee -a "$LOG_FILE"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Would push to repo: $BACKUP_REPO as release backup-${DATE}" | tee -a "$LOG_FILE"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DRY-RUN: Backup manifest:" | tee -a "$LOG_FILE"
  echo "  agent-memory-local: $BACKUP_FILE" | tee -a "$LOG_FILE"
  [[ -f "$DB_BACKUP_FILE" ]] && echo "  cast.db: $DB_BACKUP_FILE" | tee -a "$LOG_FILE"
  [[ -f "$PLANS_BACKUP_FILE" ]] && echo "  plans/: $PLANS_BACKUP_FILE" | tee -a "$LOG_FILE"
  [[ -f "$AUTOMEMORY_BACKUP_FILE" ]] && echo "  auto-memory: $AUTOMEMORY_BACKUP_FILE" | tee -a "$LOG_FILE"
  tar -tzf "$BACKUP_FILE" | head -20 | tee -a "$LOG_FILE"
  exit 0
fi

# Build gh release asset list (all backup files that exist)
GH_ASSETS=("$BACKUP_FILE")
[[ -f "$DB_BACKUP_FILE" ]] && GH_ASSETS+=("$DB_BACKUP_FILE")
[[ -f "$PLANS_BACKUP_FILE" ]] && GH_ASSETS+=("$PLANS_BACKUP_FILE")
[[ -f "$AUTOMEMORY_BACKUP_FILE" ]] && GH_ASSETS+=("$AUTOMEMORY_BACKUP_FILE")

# Push to GitHub release
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pushing to GitHub release backup-${DATE} on ${BACKUP_REPO}" | tee -a "$LOG_FILE"
gh release create "backup-${DATE}" "${GH_ASSETS[@]}" \
  --repo "$BACKUP_REPO" \
  --title "CAST backup ${DATE}" \
  --notes "Automated CAST backup — agent-memory-local, cast.db, plans, auto-memory" \
  2>&1 | tee -a "$LOG_FILE"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Backup complete. Assets: ${#GH_ASSETS[@]}" | tee -a "$LOG_FILE"
