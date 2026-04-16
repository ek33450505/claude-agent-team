#!/usr/bin/env bash
# engram-session-end.sh
# Copyright 2026 Edward Kubiak
# Apache-2.0 License
#
# Fires on: Stop hook event
# Purpose:
#   1. Process any journal files not yet in extraction_log
#   2. Bump base_identity.session_count by 1
#   3. Trigger profile update (engram-update-profile.py)
#   4. Trigger payload build (engram-build-payload.py)
#
# Always exits 0 — session end must never block.

set -euo pipefail

ENGRAM_DB="${HOME}/.claude/engram.db"
JOURNAL_DIR="${HOME}/.claude/claudes_journal"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPO_DIR}/.venv/bin/python3"
# Fall back to system python3 if no venv
if [[ ! -f "$PYTHON" ]]; then
    PYTHON="python3"
fi

LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/engram-session-end.log"

# Exit 0 always — wrapper to prevent any failure from blocking session end
_safe_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        mkdir -p "${LOG_DIR}"
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') engram-session-end.sh exited with code ${exit_code}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    exit 0
}
trap _safe_exit ERR EXIT

# ── Subprocess guard: skip in subagent context ────────────────────────────
# Subagent Stop events should not bump session_count or trigger profile updates.
# Only the main session Stop event runs the full pipeline.
if [[ "${CLAUDE_SUBPROCESS:-0}" == "1" ]]; then
    exit 0
fi

# ── Step 1: Process unextracted journals ───────────────────────────────────
if [[ -d "$JOURNAL_DIR" && -f "$ENGRAM_DB" ]]; then
    export ENGRAM_DB_PATH="${ENGRAM_DB}"
    export ENGRAM_JOURNAL_DIR="${JOURNAL_DIR}"
    export ENGRAM_REPO_DIR="${REPO_DIR}"
    "$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.db import get_connection
from src.extractors.journal_extractor import extract_signals

db_path = Path(os.environ['ENGRAM_DB_PATH'])
journal_dir = Path(os.environ['ENGRAM_JOURNAL_DIR'])

conn = get_connection(db_path=db_path)

# Get set of already-processed journal paths from extraction_log
processed = set()
try:
    rows = conn.execute(
        \"SELECT source_path FROM extraction_log WHERE source_type='journal'\"
    ).fetchall()
    processed = {row['source_path'] for row in rows if row['source_path']}
except Exception:
    pass

# Find unprocessed journals
journal_files = sorted(journal_dir.glob('*.md'))
new_files = [f for f in journal_files if str(f) not in processed]

for journal_path in new_files:
    try:
        signals = extract_signals(journal_path, db_path=db_path)
        conn.execute(
            '''INSERT OR IGNORE INTO extraction_log (source_type, source_path, signals_extracted)
               VALUES (?, ?, ?)''',
            ('journal', str(journal_path), len(signals))
        )
        conn.commit()
    except Exception:
        pass  # Non-fatal — continue with other journals
" 2>/dev/null || true
fi

# ── Step 2: Bump session_count ─────────────────────────────────────────────
if [[ -f "$ENGRAM_DB" ]]; then
    export ENGRAM_DB_PATH="${ENGRAM_DB}"
    export ENGRAM_REPO_DIR="${REPO_DIR}"
    "$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.db import get_connection

conn = get_connection(db_path=Path(os.environ['ENGRAM_DB_PATH']))
conn.execute('UPDATE base_identity SET session_count = session_count + 1 WHERE id = 1')
conn.commit()
" 2>/dev/null || true
fi

# Pass agent name if running in agent context
AGENT_NAME="${CAST_AGENT_NAME:-}"

# ── Step 2.5: Resolve active persona ──────────────────────────────────────
PERSONA_SLUG=""
PERSONA_ID=""
# Check for .engram/persona file in current directory
if [[ -f "${PWD}/.engram/persona" ]]; then
    PERSONA_SLUG=$(head -1 "${PWD}/.engram/persona" 2>/dev/null | tr -d '[:space:]')
    # Validate slug: alphanumeric, hyphens, underscores only
    if [[ -n "$PERSONA_SLUG" && ! "$PERSONA_SLUG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        PERSONA_SLUG=""  # Reject invalid slugs
    fi
fi

# Resolve persona ID and increment total_sessions
if [[ -n "$PERSONA_SLUG" && -f "$ENGRAM_DB" ]]; then
    export ENGRAM_PERSONA_SLUG="${PERSONA_SLUG}"
    PERSONA_ID=$("$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.db import get_connection
from src.personas.resolver import get_persona_by_slug

conn = get_connection(db_path=Path(os.environ['ENGRAM_DB_PATH']))
slug = os.environ.get('ENGRAM_PERSONA_SLUG', '')
if slug:
    persona = get_persona_by_slug(conn, slug)
    if persona:
        pid = persona['id']
        conn.execute('UPDATE personas SET total_sessions = total_sessions + 1, last_active_at = strftime(\"%Y-%m-%dT%H:%M:%SZ\", \"now\") WHERE id = ?', (pid,))
        conn.commit()
        print(pid)
" 2>/dev/null) || true
elif [[ -f "$ENGRAM_DB" ]]; then
    # Check for default persona
    PERSONA_ID=$("$PYTHON" -c "
import sys, os
sys.path.insert(0, os.environ['ENGRAM_REPO_DIR'])
from pathlib import Path
from src.db import get_connection

conn = get_connection(db_path=Path(os.environ['ENGRAM_DB_PATH']))
row = conn.execute('SELECT id FROM personas WHERE is_default = 1 LIMIT 1').fetchone()
if row:
    pid = row['id']
    conn.execute('UPDATE personas SET total_sessions = total_sessions + 1, last_active_at = strftime(\"%Y-%m-%dT%H:%M:%SZ\", \"now\") WHERE id = ?', (pid,))
    conn.commit()
    print(pid)
" 2>/dev/null) || true
fi

# ── Step 3: Trigger profile update ────────────────────────────────────────
PROFILE_UPDATER="${REPO_DIR}/src/extractors/profile_updater.py"
if [[ -f "$PROFILE_UPDATER" && -f "$ENGRAM_DB" ]]; then
    if [[ -n "$PERSONA_ID" && -n "$AGENT_NAME" ]]; then
        "$PYTHON" "$PROFILE_UPDATER" --db-path "$ENGRAM_DB" --persona-id "$PERSONA_ID" --agent-name "$AGENT_NAME" 2>/dev/null || true
    elif [[ -n "$PERSONA_ID" ]]; then
        "$PYTHON" "$PROFILE_UPDATER" --db-path "$ENGRAM_DB" --persona-id "$PERSONA_ID" 2>/dev/null || true
    elif [[ -n "$AGENT_NAME" ]]; then
        "$PYTHON" "$PROFILE_UPDATER" --db-path "$ENGRAM_DB" --agent-name "$AGENT_NAME" 2>/dev/null || true
    else
        "$PYTHON" "$PROFILE_UPDATER" --db-path "$ENGRAM_DB" 2>/dev/null || true
    fi
fi

# ── Step 4: Trigger payload build ─────────────────────────────────────────
PAYLOAD_BUILDER="${REPO_DIR}/src/payload/builder.py"
if [[ -f "$PAYLOAD_BUILDER" && -f "$ENGRAM_DB" ]]; then
    if [[ -n "$PERSONA_SLUG" && -n "$AGENT_NAME" ]]; then
        "$PYTHON" "$PAYLOAD_BUILDER" --db-path "$ENGRAM_DB" --persona "$PERSONA_SLUG" --agent-name "$AGENT_NAME" 2>/dev/null || true
    elif [[ -n "$PERSONA_SLUG" ]]; then
        "$PYTHON" "$PAYLOAD_BUILDER" --db-path "$ENGRAM_DB" --persona "$PERSONA_SLUG" 2>/dev/null || true
    elif [[ -n "$AGENT_NAME" ]]; then
        "$PYTHON" "$PAYLOAD_BUILDER" --db-path "$ENGRAM_DB" --agent-name "$AGENT_NAME" 2>/dev/null || true
    else
        "$PYTHON" "$PAYLOAD_BUILDER" --db-path "$ENGRAM_DB" 2>/dev/null || true
    fi
fi

exit 0
