#!/bin/bash
# SubagentStop hook fragment: capture debugger-agent incidents into cast.db
# Triggered on SubagentStop event when agent_type == "debugger" and Status: DONE is present

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# Helper for error logging
_log_error() {
  local msg="$1"
  local log_file="$HOME/.claude/logs/hook-errors.log"
  mkdir -p "$(dirname "$log_file")"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [cast-incident-record] $msg" >> "$log_file"
}

# Read CAST_INPUT from stdin (fallback to empty if unavailable)
INPUT="$(cat 2>/dev/null || true)"
if [[ -z "$INPUT" ]]; then
  _log_error "No input received from hook system"
  exit 0
fi

# Resolve DB path
DB_PATH="${CAST_DB_PATH:-$HOME/.claude/cast.db}"

# Parse JSON fields via python3 inline
# Extract agent_type, agent_id, last_message_text, original_prompt
read -r agent_type agent_id last_message_text original_prompt < <(python3 << 'PYEOF'
import sys, json, os
try:
    data = json.loads(os.environ.get('CAST_INPUT', ''))
    agent_type = data.get('agent_type', '')
    agent_id = data.get('agent_id', '')
    last_message_text = data.get('last_message_text', '')
    original_prompt = data.get('original_prompt', '')
    print(f"{agent_type} {agent_id} {last_message_text[:100]} {original_prompt[:100]}")
except Exception as e:
    print(f"error parsing json")
PYEOF
) 2>/dev/null || { _log_error "Failed to parse CAST_INPUT"; exit 0; }

# Guard: only process debugger agent with Status: DONE
if [[ "$agent_type" != "debugger" ]]; then
  exit 0
fi

if [[ ! "$last_message_text" =~ Status:\ DONE ]]; then
  exit 0
fi

# Extract problem_summary: first 200 chars of original prompt
problem_summary="${original_prompt:0:200}"
if [[ -z "$problem_summary" ]]; then
  problem_summary="(unable to extract)"
fi

# Extract fix_summary: last 30 lines of last_message_text, truncated to 1000 chars
fix_summary=$(echo "$last_message_text" | tail -30 | head -c 1000)
if [[ -z "$fix_summary" ]]; then
  fix_summary="(unable to extract)"
fi

# Extract related_files: parse Handoff block for files_changed
# Look for "files_changed: [...]" or "files_changed:" YAML-style
related_files="[]"
if echo "$last_message_text" | grep -q "files_changed"; then
  # Simple extraction: find the line, extract bracketed content
  related_files=$(echo "$last_message_text" | grep -A 5 "files_changed" | head -1 | sed 's/.*files_changed:[[:space:]]*//' || echo "[]")
fi

# Extract related_commit: latest git commit hash from cwd
related_commit=""
if command -v git &>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  related_commit=$(git log -1 --format=%H 2>/dev/null || echo "")
fi

# Generate UUID. Internally generated — safe to interpolate into SQL without escaping.
id=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen 2>/dev/null || echo "")
if [[ -z "$id" ]]; then
  _log_error "Failed to generate UUID"
  exit 0
fi

# Escape single quotes in strings for SQL
escape_sql() {
  echo "$1" | sed "s/'/''/g"
}

problem_summary_esc=$(escape_sql "$problem_summary")
fix_summary_esc=$(escape_sql "$fix_summary")
related_files_esc=$(escape_sql "$related_files")
related_commit_esc=$(escape_sql "$related_commit")

# Insert into incidents table
if sqlite3 -cmd ".timeout 5000" "$DB_PATH" <<EOF 2>/dev/null
INSERT INTO incidents (
  id,
  occurred_at,
  problem_summary,
  fix_summary,
  related_files,
  related_commit,
  resolution_status,
  surfaced_by
) VALUES (
  '$id',
  datetime('now'),
  '$problem_summary_esc',
  '$fix_summary_esc',
  '$related_files_esc',
  '$related_commit_esc',
  'open',
  'debugger'
);
EOF
then
  exit 0
else
  _log_error "Failed to insert incident record: $id"
  exit 0
fi
