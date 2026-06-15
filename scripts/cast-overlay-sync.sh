#!/usr/bin/env bash
# cast-overlay-sync.sh — sync irreplaceable ~/.claude files to your private overlay repo
#
# Purpose:
#   Maintains a local git clone of your private overlay repo as a version-controlled
#   overlay of irreplaceable local-only ~/.claude files. Runs daily via launchd.
#
# Usage:
#   bash cast-overlay-sync.sh [--dry-run]
#
# Environment overrides:
#   CAST_OVERLAY_REPO    — private repo URL (required; no default — set via env or
#                          ~/.claude/config/cast-overlay-repo, first non-empty non-comment line)
#   CAST_OVERLAY_DIR     — clone directory (default: ~/.local/share/cast/overlay)
#   CAST_CLAUDE_DIR      — source dir (default: ~/.claude)

set -euo pipefail

# Guard: do not run recursively inside CAST subprocess chains
[[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]] && exit 0

# ============================================================================
# Configuration
# ============================================================================

CAST_OVERLAY_REPO="${CAST_OVERLAY_REPO:-}"

# If CAST_OVERLAY_REPO is not set via env, try reading from local config file (gitignored)
if [[ -z "$CAST_OVERLAY_REPO" ]]; then
  _config_file="${HOME}/.claude/config/cast-overlay-repo"
  if [[ -f "$_config_file" ]]; then
    # Read first non-empty, non-comment line
    while IFS= read -r _line; do
      [[ -z "$_line" || "$_line" == \#* ]] && continue
      CAST_OVERLAY_REPO="$_line"
      break
    done < "$_config_file"
  fi
  unset _config_file _line
fi

# If still empty, print advisory and exit 0 (opt-in tool, not an error)
if [[ -z "$CAST_OVERLAY_REPO" ]]; then
  echo "ADVISORY [cast-overlay-sync]: no overlay repo configured. Set CAST_OVERLAY_REPO=<your-private-repo-url> (or add the URL to ~/.claude/config/cast-overlay-repo) to enable off-machine overlay sync." >&2
  exit 0
fi

CAST_OVERLAY_DIR="${CAST_OVERLAY_DIR:-${HOME}/.local/share/cast/overlay}"
CAST_CLAUDE_DIR="${CAST_CLAUDE_DIR:-${HOME}/.claude}"

DRY_RUN=0
LOG_FILE="${HOME}/.claude/logs/cast-overlay-sync.log"

# Color helpers
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  RESET='\033[0m'
else
  GREEN='' YELLOW='' RED='' RESET=''
fi

# shellcheck disable=SC2034
info()  { echo -e "${GREEN}[overlay]${RESET} $*"; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [info] $*" >> "$LOG_FILE"; }
# shellcheck disable=SC2329
warn()  { echo -e "${YELLOW}[warn]${RESET} $*" >&2; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [warn] $*" >> "$LOG_FILE"; }
error() { echo -e "${RED}[error]${RESET} $*" >&2; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [error] $*" >> "$LOG_FILE"; }

# ============================================================================
# Argument parsing
# ============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ============================================================================
# Logging setup
# ============================================================================

mkdir -p "$(dirname "$LOG_FILE")"

# ============================================================================
# Secrets check
# ============================================================================

_is_secret() {
  local file="$1"
  local basename
  basename="$(basename "$file")"

  # Case-insensitive basename match
  local lower_basename
  lower_basename="$(echo "$basename" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower_basename" =~ \.env$ ]] ||
     [[ "$lower_basename" =~ \.env\. ]] ||
     [[ "$lower_basename" =~ \.(pem|key|p12|pfx)$ ]] ||
     [[ "$lower_basename" =~ (api_key|secret|credentials) ]] ||
     [[ "$lower_basename" =~ ^(id_rsa|id_dsa|id_ecdsa|id_ed25519)$ ]]; then
    return 0  # is secret
  fi
  return 1  # not secret
}

_has_secret_content() {
  # Scan STAGED files for secret content.
  # Return convention (matches caller `if _has_secret_content; then abort`):
  #   0 = secrets found, 1 = clean.
  # Grep patterns are the PRIMARY, always-run check (reliable, no deps).
  # gitleaks, if present, is an ADDITIVE layer — it must never replace/skip the grep.
  local secrets_found=1  # 1 = clean

  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue
    if grep -iEq '(sk-ant-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|"(api[_-]?key|secret|token|password)"[[:space:]]*:[[:space:]]*"[^"]{12,}"|xox[bpasr]-[A-Za-z0-9-]{10,}|[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}|glpat-[A-Za-z0-9_-]{20,})' "$file" 2>/dev/null; then
      error "Secret pattern detected in: $file"
      secrets_found=0  # 0 = found
    fi
  done < <(git diff --cached --name-only)

  # Additive layer: gitleaks via EXIT CODE (1 = leaks). Other non-zero = tool error → ignore (grep is the net).
  if command -v gitleaks &>/dev/null; then
    local gl_rc=0
    gitleaks protect --staged --no-banner >/dev/null 2>&1 || gl_rc=$?
    if [[ "$gl_rc" -eq 1 ]]; then
      error "gitleaks flagged staged content"
      secrets_found=0
    fi
  fi

  return "$secrets_found"
}

# ============================================================================
# Ensure clone exists
# ============================================================================

if [[ ! -d "$CAST_OVERLAY_DIR" ]]; then
  info "Overlay dir not found at $CAST_OVERLAY_DIR, creating repo..."

  # Best-effort create private repo (no-op if exists)
  # Strip any scheme/host prefix (https://github.com/ or SSH host:) and the .git suffix.
  repo_slug="${CAST_OVERLAY_REPO##*github.com[:/]}"
  repo_slug="${repo_slug%.git}"
  gh repo create "$repo_slug" --private 2>/dev/null || true

  # Clone the repo
  mkdir -p "$(dirname "$CAST_OVERLAY_DIR")"
  if ! git clone "$CAST_OVERLAY_REPO" "$CAST_OVERLAY_DIR" 2>&1 | tee -a "$LOG_FILE"; then
    error "Failed to clone $CAST_OVERLAY_REPO"
    exit 1
  fi
fi

# ============================================================================
# Enter overlay dir and ensure main branch
# ============================================================================

cd "$CAST_OVERLAY_DIR"

# Check if remote main branch exists; if not, just use local main
if git ls-remote --exit-code --heads origin main &>/dev/null 2>&1; then
  info "Pulling from origin main..."
  if ! git pull --rebase origin main 2>&1 | tee -a "$LOG_FILE"; then
    error "Failed to pull from origin"
    exit 1
  fi
else
  # Fresh repo with no main branch upstream — ensure local main exists
  info "Remote main not found; ensuring local main branch..."
  git checkout -B main 2>&1 | tee -a "$LOG_FILE"
fi

# ============================================================================
# Copy files from CAST_CLAUDE_DIR
# ============================================================================

info "Copying irreplaceable files from $CAST_CLAUDE_DIR..."

# List of file patterns to copy (globs relative to CAST_CLAUDE_DIR)
declare -a COPY_PATTERNS=(
  "config/pii-denylist-local.txt"
  "config/sync.json"
  "projects/*/memory/*.md"
  "agent-memory-local/**/*.md"
  "rules/*.md"
  "CLAUDE.md"
  "settings.local.json"
  "agents/personal/*.md"
)

FILES_COPIED=0
declare -a STAGED_FILES=()

for pattern in "${COPY_PATTERNS[@]}"; do
  # Expand glob in the source directory
  while IFS= read -r srcfile; do
    [[ -z "$srcfile" ]] && continue

    # Resolve full path (srcfile is relative to CAST_CLAUDE_DIR)
    full_srcfile="$CAST_CLAUDE_DIR/$srcfile"

    # Skip if source doesn't exist
    [[ ! -f "$full_srcfile" ]] && continue

    # Skip secrets
    if _is_secret "$full_srcfile"; then
      info "Skipping secret: $srcfile"
      continue
    fi

    # Compute destination path (preserve relative subpath from CAST_CLAUDE_DIR)
    dest_file="$CAST_OVERLAY_DIR/$srcfile"
    dest_dir="$(dirname "$dest_file")"

    # Create destination directory and copy file
    mkdir -p "$dest_dir"
    if cp "$full_srcfile" "$dest_file" 2>&1 | tee -a "$LOG_FILE"; then
      info "Copied: $srcfile"
      FILES_COPIED=$((FILES_COPIED + 1))
      STAGED_FILES+=("$dest_file")
    else
      error "Failed to copy: $srcfile"
    fi
  done < <(cd "$CAST_CLAUDE_DIR" && find . -path "./$pattern" -type f 2>/dev/null | sed 's|^\./||')
done

# ============================================================================
# Stage files explicitly (never git add -A)
# ============================================================================

info "Staging files..."

# Stage the copied files from our array
for dest_file in "${STAGED_FILES[@]}"; do
  # Use -f/--force to override .gitignore for this repo's files
  git add -f -- "$dest_file" 2>&1 | tee -a "$LOG_FILE"
done

# ============================================================================
# Check if there's anything staged
# ============================================================================

if git diff --staged --quiet; then
  info "Nothing to commit (no changes staged)"
  exit 0
fi

# ============================================================================
# Security: scan staged files for secret content
# ============================================================================

if _has_secret_content; then
  error "Secret patterns detected in staged files. Aborting commit."
  error "Review staged files and remove secrets before retrying:"
  error "  git diff --staged | grep -i secret"
  git reset 2>&1 | tee -a "$LOG_FILE"
  exit 1
fi

# ============================================================================
# Commit (unless dry-run)
# ============================================================================

if [[ $DRY_RUN -eq 1 ]]; then
  info "DRY-RUN: showing git diff --stat"
  git diff --staged --stat 2>&1 | tee -a "$LOG_FILE"
  exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT_MSG="chore: cast overlay sync $TIMESTAMP"

info "Committing with message: $COMMIT_MSG"
if ! git commit -m "$COMMIT_MSG" 2>&1 | tee -a "$LOG_FILE"; then
  error "Failed to commit"
  exit 1
fi

# ============================================================================
# Push (non-dry-run only)
# ============================================================================

info "Pushing to origin main..."
if ! git push origin main 2>&1 | tee -a "$LOG_FILE"; then
  error "Failed to push to origin main"
  exit 1
fi

info "Overlay sync complete"
exit 0
