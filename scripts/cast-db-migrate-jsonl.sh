#!/bin/bash
# cast-db-migrate-jsonl.sh — Migrate CAST JSONL logs to SQLite
# Migrates:
#   ~/.claude/routing-log.jsonl     → routing_events table
#   ~/.claude/cast/events/*.json    → agent_runs table
#
# Preserves original files (never deletes them).
# --dry-run: prints what would be migrated without writing.
#
# Usage:
#   cast-db-migrate-jsonl.sh [--dry-run] [--db /path/to/cast.db]

set -euo pipefail

DRY_RUN=0
DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --db)      shift; DB_PATH="$1" ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

ROUTING_LOG="${HOME}/.claude/routing-log.jsonl"
EVENTS_DIR="${HOME}/.claude/cast/events"

# Check for sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 not found in PATH." >&2
  exit 1
fi

# Ensure db exists (unless dry-run)
if [ "$DRY_RUN" = "0" ]; then
  if [ ! -f "$DB_PATH" ]; then
    DB_INIT_SCRIPT="$(dirname "$0")/cast-db-init.sh"
    if [ -f "$DB_INIT_SCRIPT" ]; then
      bash "$DB_INIT_SCRIPT" --db "$DB_PATH"
    else
      # Try installed location
      bash "${HOME}/.claude/scripts/cast-db-init.sh" --db "$DB_PATH"
    fi
  fi
fi

# Run the migration via Python for JSON parsing robustness
DRY_RUN_VAL="$DRY_RUN" DB_PATH_VAL="$DB_PATH" \
  ROUTING_LOG_VAL="$ROUTING_LOG" EVENTS_DIR_VAL="$EVENTS_DIR" \
  python3 -c "
import json, os, sys, glob, sqlite3 as _sqlite3, datetime

dry_run    = os.environ.get('DRY_RUN_VAL', '0') == '1'
db_path    = os.environ.get('DB_PATH_VAL', '')
routing_log = os.environ.get('ROUTING_LOG_VAL', '')
events_dir  = os.environ.get('EVENTS_DIR_VAL', '')

# -----------------------------------------------------------------------
# Phase 1: routing-log.jsonl -> routing_events
# -----------------------------------------------------------------------
routing_rows = []
routing_skipped = 0
routing_source = 'not found'

if os.path.exists(routing_log):
    routing_source = routing_log
    with open(routing_log) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                routing_skipped += 1
                continue
            routing_rows.append((
                entry.get('session_id', 'unknown'),
                entry.get('timestamp', ''),
                entry.get('prompt_preview', ''),
                entry.get('action', ''),
                entry.get('matched_route'),
                entry.get('match_type'),
                entry.get('pattern'),
                entry.get('confidence'),
                entry.get('project'),
            ))

# -----------------------------------------------------------------------
# Phase 2: cast/events/*.json -> agent_runs
# -----------------------------------------------------------------------
agent_rows = []
agent_skipped = 0
event_files_found = 0

if os.path.isdir(events_dir):
    event_files = sorted(glob.glob(os.path.join(events_dir, '*.json')))
    event_files_found = len(event_files)
    for fpath in event_files:
        try:
            with open(fpath) as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            agent_skipped += 1
            continue
        # Map event fields to agent_runs schema
        agent_rows.append((
            event.get('session_id'),
            event.get('agent', ''),
            event.get('model'),
            event.get('started_at') or event.get('timestamp'),
            event.get('ended_at'),
            event.get('status'),
            event.get('input_tokens'),
            event.get('output_tokens'),
            event.get('cost_usd'),
            (event.get('task') or event.get('message') or '')[:200],
            None,   # prompt — omit for privacy
            event.get('project'),
        ))

# -----------------------------------------------------------------------
# Dry-run output
# -----------------------------------------------------------------------
if dry_run:
    print('--- DRY RUN: no data will be written ---')
    print()
    print(f'routing-log.jsonl ({routing_source}):')
    print(f'  {len(routing_rows)} rows would be inserted into routing_events')
    if routing_skipped:
        print(f'  {routing_skipped} lines skipped (malformed JSON)')
    if routing_rows:
        sample = routing_rows[0]
        print(f'  Sample: session={sample[0][:12]}... action={sample[3]} route={sample[4]}')
    print()
    print(f'cast/events/*.json ({events_dir}):')
    print(f'  {event_files_found} event files found')
    print(f'  {len(agent_rows)} rows would be inserted into agent_runs')
    if agent_skipped:
        print(f'  {agent_skipped} files skipped (malformed JSON / unreadable)')
    if agent_rows:
        sample = agent_rows[0]
        print(f'  Sample: agent={sample[1]} status={sample[5]} model={sample[2]}')
    print()
    print('Original files preserved (no writes performed).')
    sys.exit(0)

# -----------------------------------------------------------------------
# Live migration
# -----------------------------------------------------------------------
conn = _sqlite3.connect(db_path)
cur = conn.cursor()

# Check existing counts to avoid double-migration
cur.execute('SELECT COUNT(*) FROM routing_events')
existing_routing = cur.fetchone()[0]

cur.execute('SELECT COUNT(*) FROM agent_runs')
existing_runs = cur.fetchone()[0]

routing_inserted = 0
agent_inserted = 0

if routing_rows:
    cur.executemany(
        '''INSERT OR IGNORE INTO routing_events
           (session_id, timestamp, prompt_preview, action, matched_route,
            match_type, pattern, confidence, project)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        routing_rows
    )
    routing_inserted = cur.rowcount if cur.rowcount >= 0 else len(routing_rows)

if agent_rows:
    cur.executemany(
        '''INSERT INTO agent_runs
           (session_id, agent, model, started_at, ended_at, status,
            input_tokens, output_tokens, cost_usd, task_summary, prompt, project)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        agent_rows
    )
    agent_inserted = cur.rowcount if cur.rowcount >= 0 else len(agent_rows)

conn.commit()
conn.close()

print('Migration complete.')
print()
print(f'routing_events:')
print(f'  Prior rows: {existing_routing}')
print(f'  Inserted:   {len(routing_rows)}')
if routing_skipped:
    print(f'  Skipped (malformed): {routing_skipped}')
print()
print(f'agent_runs:')
print(f'  Prior rows: {existing_runs}')
print(f'  Inserted:   {len(agent_rows)}')
if agent_skipped:
    print(f'  Skipped (unreadable): {agent_skipped}')
print()
print('Original files preserved.')
" 2>&1
