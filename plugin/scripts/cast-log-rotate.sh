#!/usr/bin/env bash
# cast-log-rotate.sh — runtime cruft rotation for CAST (events, logs, legacy backups).
#
# Replaces the broken `log-compress` launchd job, which gzipped
# `~/.claude/cast/events -name '*.jsonl'` — but events are written as `*.json`,
# so it matched nothing, never deleted anything, and never touched ~/.claude/logs.
#
# What this does (all paths hard-guarded to ~/.claude; idempotent; exit 0 always):
#   1. cast/events  — gzip *.json older than EVENTS_GZIP_DAYS, delete *.json/*.json.gz
#                     older than EVENTS_DELETE_DAYS (keeps recent for cast-stats.sh).
#   2. ~/.claude/logs — gzip *.log / *.jsonl older than LOGS_GZIP_DAYS (active same-day
#                     logs are skipped by the mtime filter), delete *.gz older than
#                     LOGS_DELETE_DAYS.
#   3. ~/.claude/backups (LEGACY, colocated inside the wipe blast radius) — prune the
#                     harness-written .claude.json.backup.* files older than
#                     LEGACY_BACKUP_DAYS. CAST's real backups already live off-blast-radius
#                     under ~/Library/Application Support/cast/.
#
# Overridable via env. Run by com.cast.log-compress (daily 03:45).

set -euo pipefail

# ── Subprocess guard (CAST convention) ────────────────────────────────────
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then exit 0; fi

CLAUDE_HOME="${HOME}/.claude"
EVENTS_DIR="${CLAUDE_HOME}/cast/events"
LOGS_DIR="${CLAUDE_HOME}/logs"
LEGACY_BACKUP_DIR="${CLAUDE_HOME}/backups"

EVENTS_GZIP_DAYS="${CAST_EVENTS_GZIP_DAYS:-7}"
EVENTS_DELETE_DAYS="${CAST_EVENTS_DELETE_DAYS:-30}"
LOGS_GZIP_DAYS="${CAST_LOGS_GZIP_DAYS:-3}"
LOGS_DELETE_DAYS="${CAST_LOGS_DELETE_DAYS:-30}"
LEGACY_BACKUP_DAYS="${CAST_LEGACY_BACKUP_DAYS:-7}"
LEGACY_BACKUP_DIR_DAYS="${CAST_LEGACY_BACKUP_DIR_DAYS:-14}"

_log() { printf '[cast-log-rotate] %s\n' "$1"; }

# Fail-closed guard: only ever operate inside ~/.claude.
_guard() {
  case "$1" in
    "${CLAUDE_HOME}"/*) return 0 ;;
    *) _log "GUARD: refusing to operate outside ~/.claude: $1"; return 1 ;;
  esac
}

# Blast-radius guard primitive — required for any recursive delete (CAST blast-radius-lint).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/cast-guard-lib.sh" 2>/dev/null \
  || source "${HOME}/.claude/scripts/cast-guard-lib.sh" 2>/dev/null \
  || true

# ── 1. cast/events ─────────────────────────────────────────────────────────
if [[ -d "$EVENTS_DIR" ]] && _guard "$EVENTS_DIR"; then
  find "$EVENTS_DIR" -type f -name '*.json' -mtime "+${EVENTS_GZIP_DAYS}" -exec gzip -f {} \; 2>/dev/null || true
  find "$EVENTS_DIR" -type f \( -name '*.json' -o -name '*.json.gz' \) \
    -mtime "+${EVENTS_DELETE_DAYS}" -delete 2>/dev/null || true
  _log "events rotated (gzip +${EVENTS_GZIP_DAYS}d, delete +${EVENTS_DELETE_DAYS}d): $(find "$EVENTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ') files remain"
fi

# ── 2. ~/.claude/logs ──────────────────────────────────────────────────────
if [[ -d "$LOGS_DIR" ]] && _guard "$LOGS_DIR"; then
  # gzip rotated/idle logs (same-day active logs are excluded by the mtime filter)
  find "$LOGS_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.jsonl' \) \
    ! -name '*.gz' -mtime "+${LOGS_GZIP_DAYS}" -exec gzip -f {} \; 2>/dev/null || true
  find "$LOGS_DIR" -maxdepth 1 -type f -name '*.gz' \
    -mtime "+${LOGS_DELETE_DAYS}" -delete 2>/dev/null || true
  _log "logs rotated (gzip +${LOGS_GZIP_DAYS}d, delete +${LOGS_DELETE_DAYS}d): $(du -sh "$LOGS_DIR" 2>/dev/null | cut -f1)"
fi

# ── 3. legacy colocated backups (harness-written, inside blast radius) ──────
# CAST's real backups live off-blast-radius under ~/Library/Application Support/cast/.
# This dir holds redundant harness config backups; keep it from growing inside ~/.claude.
if [[ -d "$LEGACY_BACKUP_DIR" ]] && _guard "$LEGACY_BACKUP_DIR"; then
  # 3a. harness-written .claude.json.backup.* files (5+/day)
  find "$LEGACY_BACKUP_DIR" -maxdepth 1 -type f -name '.claude.json.backup.*' \
    -mtime "+${LEGACY_BACKUP_DAYS}" -delete 2>/dev/null || true
  # 3b. old timestamped config-snapshot dirs (YYYYMMDD-HHMMSS) — deleted via the
  # cast_safe_rm blast-radius primitive (canonicalizes + deny-lists / $HOME / ~/.claude,
  # requires the path to be strictly inside the declared radius). Skipped fail-closed
  # if the guard lib could not be sourced.
  if declare -f cast_safe_rm >/dev/null 2>&1; then
    cast_declare_blast_radius "${LEGACY_BACKUP_DIR}/"
    while IFS= read -r _d; do
      [[ -z "$_d" ]] && continue
      case "$_d" in
        "${LEGACY_BACKUP_DIR}"/20*-*) cast_safe_rm "$_d" >/dev/null 2>&1 || true ;;
      esac
    done < <(find "$LEGACY_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*-*' \
               -mtime "+${LEGACY_BACKUP_DIR_DAYS}" 2>/dev/null || true)
  fi
  _log "legacy backups pruned (files +${LEGACY_BACKUP_DAYS}d, dirs +${LEGACY_BACKUP_DIR_DAYS}d): $(du -sh "$LEGACY_BACKUP_DIR" 2>/dev/null | cut -f1)"
fi

exit 0
