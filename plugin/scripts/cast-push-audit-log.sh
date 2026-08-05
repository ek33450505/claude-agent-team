#!/bin/bash
# cast-push-audit-log.sh — audit-log helper for cast-push.sh's CAST_PUSH_OK escape-hatch use.
# Sourced helper — do NOT execute directly.
#
# Usage:
#   source ~/.claude/scripts/cast-push-audit-log.sh
#   cast_push_write_audit_log "<branch>" "<sha>"
#
# Appends one tab-separated line to ~/.claude/logs/cast-push-audit.log.
# Never fails the caller even if the log dir is unwritable.

cast_push_write_audit_log() {
  local branch="$1"
  local sha="$2"

  mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$branch" "$sha" >>"$HOME/.claude/logs/cast-push-audit.log" 2>/dev/null || true
}
