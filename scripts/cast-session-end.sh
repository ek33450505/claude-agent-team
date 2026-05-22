#!/bin/bash
# cast-session-end.sh — CAST consolidated session-end hook
# Hook events: Stop, SessionEnd
# Timeout: 15 seconds
#
# Replaces: stop-hook.sh, cast-archive.sh, cast-agent-memory-sync.sh,
#           and the inline blocked-count bash from settings.local.json
#
# Purpose:
#   On session end, perform all CAST cleanup and maintenance tasks:
#   - Touch hook-health marker
#   - Escalate on repeated BLOCKED responses
#   - Refresh project board (background)
#   - Run agent memory auto-init (background)
#   - Run auto-escalation rule engine (background)
#   - Archive stale files from ~/.claude/ to ~/Archive/claude-archive-auto/
#   - Prune old rows from cast.db
#   - Sync agent-memory-local/*.md files to cast.db agent_memories table
#   - Clean CAST temp files for this session
#
# Exit codes:
#   0 — always (hook must NEVER block session close)

# --- Subprocess guard (must be first) ---
if [[ "${CLAUDE_SUBPROCESS:-0}" = "1" ]]; then exit 0; fi

set +e

# _log_error: append a structured error line to hook-errors.log (never fails itself)
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }

# === HOOK HEALTH MARKER ===
mkdir -p "${HOME}/.claude/cast/hook-last-fired" && touch "${HOME}/.claude/cast/hook-last-fired/Stop.timestamp" "${HOME}/.claude/cast/hook-last-fired/SessionEnd.timestamp"

CAST_DIR="${HOME}/.claude/cast"
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
CAST_SCRIPTS_DIR="${HOME}/.claude/scripts"

# === SESSION_ID SAFETY GUARD ===
# Reject any SESSION_ID that contains characters outside [a-zA-Z0-9_-] to prevent
# SQL injection via interpolation into sqlite3 CLI calls below.
if [[ ! "${SESSION_ID}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  _log_error "cast-session-end: Refusing unsafe SESSION_ID: ${SESSION_ID:0:40}"
  exit 0
fi

# === BLOCKED COUNT ESCALATION ===
BLOCKED_LOG="${CAST_DIR}/blocked-count.txt"
BLOCKED_COUNT=$(cat "$BLOCKED_LOG" 2>/dev/null || echo 0)
if [[ "${BLOCKED_COUNT}" -ge 2 ]] 2>/dev/null; then
  echo "[CAST-ESCALATE] WARNING: ${BLOCKED_COUNT} consecutive BLOCKED responses detected. Human intervention may be required. Check ${CAST_DIR}/events/ for details." >&2
  rm -f "$BLOCKED_LOG"
fi

# === BACKGROUND TASKS ===

# Project board refresh
CAST_BOARD="${CAST_SCRIPTS_DIR}/cast-board.sh"
if [[ -f "$CAST_BOARD" ]]; then
  bash "$CAST_BOARD" > "${TMPDIR:-/tmp}/cast-board-last.log" 2>&1 &
fi

# Agent memory auto-initialization
CAST_AGENT_MEM_INIT="${CAST_SCRIPTS_DIR}/cast-agent-memory-init.sh"
if [[ -f "$CAST_AGENT_MEM_INIT" ]]; then
  bash "$CAST_AGENT_MEM_INIT" > "${TMPDIR:-/tmp}/cast-agent-memory-init-last.log" 2>&1 &
fi

# Auto-escalation rule engine
CAST_MEM_ESCALATION="${CAST_SCRIPTS_DIR}/cast-memory-escalation.sh"
if [[ -f "$CAST_MEM_ESCALATION" ]]; then
  bash "$CAST_MEM_ESCALATION" > "${TMPDIR:-/tmp}/cast-memory-escalation-last.log" 2>&1 &
fi

# === ARCHIVE STALE FILES ===
# TTL config (days)
TTL_PLANS=14
TTL_DEBUG=7
TTL_SHELL_SNAPSHOTS=14
TTL_PASTE_CACHE=7
TTL_REPORTS=30
TTL_DB_ROWS=90

CLAUDE_DIR="${HOME}/.claude"
ARCHIVE_BASE="${HOME}/Archive/claude-archive-auto"

# archive_category <src_dir> <name_pat_or_empty> <type_f_flag> <dest_subdir> <ttl_days> <label>
# name_pat_or_empty: glob for -name, pass "" to skip
# type_f_flag: "1" to add -type f, "0" to omit
archive_category() {
  local src="$1"
  local name_pat="$2"
  local type_f="$3"
  local dest_sub="$4"
  local ttl="$5"
  local label="$6"

  [[ -d "$src" ]] || return 0

  local dest="${ARCHIVE_BASE}/${dest_sub}"
  local count=0
  local dest_created=0

  local find_cmd=( find "$src" -maxdepth 1 )
  [[ -n "$name_pat" ]] && find_cmd+=( -name "$name_pat" )
  [[ "$type_f" = "1" ]] && find_cmd+=( -type f )
  find_cmd+=( -mtime +"$ttl" -print0 )

  while IFS= read -r -d '' f; do
    [[ -L "$f" ]] && continue
    [[ -f "$f" ]] || continue

    if [[ "$dest_created" -eq 0 ]]; then
      mkdir -p "$dest" 2>/dev/null || { echo "[cast-session-end] WARN: cannot create ${dest}" >&2; return 0; }
      dest_created=1
    fi
    if ! mv "$f" "$dest/" 2>/dev/null; then
      echo "[cast-session-end] WARN: failed to archive ${f}" >&2
      continue
    fi
    count=$((count + 1))
  done < <( "${find_cmd[@]}" 2>/dev/null )

  if [[ "$count" -gt 0 ]]; then
    echo "[cast-session-end] archive ${label}: ${count} archived → ~/Archive/claude-archive-auto/${dest_sub}" >&2
  fi
}

(
  # Plans: date-prefixed completed plans only
  archive_category \
    "${CLAUDE_DIR}/plans" \
    "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md" \
    "0" \
    "plans" \
    "$TTL_PLANS" \
    "plans"

  # Debug logs: *.txt files only (symlink guard skips 'latest')
  archive_category \
    "${CLAUDE_DIR}/debug" \
    "*.txt" \
    "0" \
    "debug" \
    "$TTL_DEBUG" \
    "debug"

  # Shell snapshots: all regular files
  archive_category \
    "${CLAUDE_DIR}/shell-snapshots" \
    "" \
    "1" \
    "shell-snapshots" \
    "$TTL_SHELL_SNAPSHOTS" \
    "shell-snapshots"

  # Paste cache: all regular files
  archive_category \
    "${CLAUDE_DIR}/paste-cache" \
    "" \
    "1" \
    "paste-cache" \
    "$TTL_PASTE_CACHE" \
    "paste-cache"

  # Reports: all regular files
  archive_category \
    "${CLAUDE_DIR}/reports" \
    "" \
    "1" \
    "reports" \
    "$TTL_REPORTS" \
    "reports"
) &

# === UPDATE sessions.ended_at + FINAL COST CAPTURE ===
DB="${CLAUDE_DIR}/cast.db"
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$DB" ]]; then
  ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "UPDATE sessions SET ended_at = '${ENDED_AT}', status = 'ended' WHERE id = '${SESSION_ID}' AND ended_at IS NULL;" 2>/dev/null || true

  # Aggregate token counts and cost from agent_runs for this session
  sqlite3 "$DB" "UPDATE sessions SET
    total_input_tokens = COALESCE((SELECT SUM(input_tokens) FROM agent_runs WHERE session_id = '${SESSION_ID}'), 0),
    total_output_tokens = COALESCE((SELECT SUM(output_tokens) FROM agent_runs WHERE session_id = '${SESSION_ID}'), 0),
    total_cost_usd = COALESCE((SELECT SUM(cost_usd) FROM agent_runs WHERE session_id = '${SESSION_ID}'), 0)
    WHERE id = '${SESSION_ID}';" 2>/dev/null || true
fi

# === DB PRUNING ===
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$DB" ]]; then
  sqlite3 "$DB" "DELETE FROM agent_runs WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM sessions WHERE started_at < datetime('now', '-${TTL_DB_ROWS} days');" 2>/dev/null || true
  # Prompt/routing data is more sensitive — hard-capped at 30 days regardless of TTL_DB_ROWS
  sqlite3 "$DB" "DELETE FROM routing_events WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
  # Additional tables with 30-day retention (audit remediation 2026-04-16)
  sqlite3 "$DB" "DELETE FROM dispatch_decisions WHERE created_at < datetime('now', '-30 days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM quality_gates WHERE created_at < datetime('now', '-30 days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM stream_events WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM stream_hook_events WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM worktree_events WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
  sqlite3 "$DB" "DELETE FROM cast_events WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
  # Convert ghost rows (stuck 'running') older than 2 hours to 'failed'
  sqlite3 "$DB" "UPDATE agent_runs SET status='failed' WHERE status='running' AND started_at < datetime('now', '-2 hours');" 2>/dev/null || true
fi

# === PANE BINDINGS UPDATE ===
if [[ -f "$DB" ]]; then
  python3 - "$DB" "$SESSION_ID" <<'PYEOF_PANE' 2>/dev/null || _log_error "pane-bindings end update failed"
import os
import sys
import sqlite3
from datetime import datetime, timezone

db_path = sys.argv[1]
session_id = sys.argv[2]

try:
    con = sqlite3.connect(db_path, timeout=3)
    # Update ended_at for pane bindings associated with this session
    con.execute(
        "UPDATE pane_bindings SET ended_at = strftime('%s','now') WHERE session_id = ? AND ended_at IS NULL",
        (session_id,),
    )
    con.commit()
    con.close()
except Exception as e:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "hook-errors.log"), "a") as lf:
        lf.write(f"[{ts}] ERROR cast-session-end: pane-bindings UPDATE failed: {type(e).__name__}: {e}\n")
PYEOF_PANE
fi

# === AGENT MEMORY DB SYNC ===
MEMORY_DIR="${HOME}/.claude/agent-memory-local"
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

if [[ -f "$DB_PATH" ]] && [[ -d "$MEMORY_DIR" ]]; then
  python3 - "$DB_PATH" "$MEMORY_DIR" <<'PYEOF' 2>/dev/null || true
import sys
import os
import sqlite3
import datetime
import glob

db_path = sys.argv[1]
memory_dir = sys.argv[2]

inserted = 0
updated = 0
errors = 0

def parse_frontmatter(content):
    lines = content.split('\n')
    if not lines or lines[0].strip() != '---':
        return {}, content

    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            end_idx = i
            break

    if end_idx is None:
        return {}, content

    frontmatter_lines = lines[1:end_idx]
    body_lines = lines[end_idx + 1:]

    fields = {}
    for line in frontmatter_lines:
        if ':' in line:
            key, _, val = line.partition(':')
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
                val = val[1:-1]
            if key:
                fields[key] = val

    body = '\n'.join(body_lines).strip()
    return fields, body


try:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
except Exception as e:
    print(f"[CAST-WARN] cast-session-end: cannot connect to {db_path}: {e}", file=sys.stderr)
    sys.exit(1)

now = datetime.datetime.utcnow().isoformat() + 'Z'

agent_dirs = [
    d for d in os.listdir(memory_dir)
    if os.path.isdir(os.path.join(memory_dir, d))
]

for agent in sorted(agent_dirs):
    agent_dir = os.path.join(memory_dir, agent)
    md_files = glob.glob(os.path.join(agent_dir, '*.md'))

    for fpath in sorted(md_files):
        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                raw = f.read()
        except Exception as e:
            print(f"[ERROR] Could not read {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

        try:
            fields, body = parse_frontmatter(raw)
        except Exception as e:
            print(f"[ERROR] Could not parse frontmatter in {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

        name = fields.get('name', '') or os.path.splitext(os.path.basename(fpath))[0]
        description = fields.get('description', '') or ''
        mem_type = fields.get('type', '') or ''
        content = body

        if not name:
            continue

        try:
            cur.execute(
                "SELECT id FROM agent_memories WHERE agent = ? AND name = ?",
                (agent, name)
            )
            row = cur.fetchone()

            if row:
                cur.execute(
                    """UPDATE agent_memories
                       SET content = ?, description = ?, type = ?, updated_at = ?
                       WHERE agent = ? AND name = ?""",
                    (content, description, mem_type, now, agent, name)
                )
                updated += 1
            else:
                cur.execute(
                    """INSERT INTO agent_memories
                       (agent, project, type, name, description, content, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (agent, None, mem_type, name, description, content, now, now)
                )
                inserted += 1

        except Exception as e:
            print(f"[ERROR] DB operation failed for {fpath}: {e}", file=sys.stderr)
            errors += 1
            continue

conn.commit()
conn.close()

print(f"cast-session-end: memory sync {inserted} inserted, {updated} updated, {errors} errors", file=sys.stderr)
PYEOF
fi

# === SESSION DISTILLER — extract memories from transcript ===
DISTILLER="${HOME}/.claude/scripts/cast-session-distiller.py"
if [[ -f "$DISTILLER" && -n "$CAST_SESSION_TRANSCRIPT" ]]; then
  echo "$CAST_SESSION_TRANSCRIPT" | \
    python3 "$DISTILLER" --min-importance 0.7 \
    >> "${HOME}/.claude/logs/distiller.log" 2>&1 || true
fi

# === TEMP FILE CLEANUP ===
rm -f "${TMPDIR:-/tmp}/cast-depth-${PPID}.depth" 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/cast-blocked-${SESSION_ID}"*.count 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/cast-dispatch-${SESSION_ID}.log" 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/cast-session-start-${SESSION_ID}.epoch" 2>/dev/null || true

exit 0
